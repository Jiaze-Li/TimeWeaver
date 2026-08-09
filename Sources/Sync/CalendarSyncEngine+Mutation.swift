import Foundation
import EventKit

extension CalendarSyncEngine {
    func syncSource(
        source: SourceItem,
        extraction: ExtractionResult,
        state: inout SyncState,
        upcomingOnly: Bool,
        previewOnly: Bool,
        aiApprovals: [AIApprovalRecord],
        titleOverrides: [Date: String] = [:]
    ) throws -> SourceSyncReport {
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == source.calendar }) else {
            throw AppFailure.calendarNotFound(source.calendar)
        }

        if !previewOnly, extraction.reviewRequired {
            let sourceKey = sourceIdentity(for: source)
            let isApproved = aiApprovals.contains {
                $0.sourceKey == sourceKey && $0.workbookFingerprint == extraction.workbookFingerprint
            }
            if !isApproved {
                throw AppFailure.syncFailed("AI parse needs review first. Run Preview, then click Approve AI before Sync.")
            }
        }

        var actions: [EventAction] = []
        let events = extraction.filteredEvents
        let activeKeys = Set(events.map(\.syncKey))

        for event in events {
            let customURL = primaryEventURL(for: event.syncKey)!
            let existingRecord = state.events[event.syncKey]
            let existingEvent = findExistingEvent(for: event, stateRecord: existingRecord, calendar: calendar, customURL: customURL)
            let target = existingEvent ?? store.makeEvent()
            let oldSignature = existingEvent.map(eventSignature) ?? ""

            let resolvedTitle = titleOverrides[event.start] ?? event.sourceName
            target.calendar = calendar
            target.title = resolvedTitle
            target.startDate = event.start
            target.endDate = event.end
            target.isAllDay = event.isAllDay
            target.notes = event.sourceLink
            target.url = customURL

            let newSignature = eventSignature(target)
            let status: String
            let mutation = TimeWeaverCore.determineUpsertMutation(
                hasExistingEvent: existingEvent != nil,
                oldSignature: oldSignature,
                newSignature: newSignature
            )
            if mutation == .create {
                status = previewOnly ? "would create" : "created"
                if !previewOnly {
                    try store.save(target, span: .thisEvent, commit: true)
                }
            } else if mutation == .update {
                status = previewOnly ? "would update" : "updated"
                if !previewOnly {
                    try store.save(target, span: .thisEvent, commit: true)
                }
            } else {
                status = "unchanged"
            }

            actions.append(EventAction(status: status, title: resolvedTitle, start: event.start, end: event.end))
            if !previewOnly, let identifier = target.eventIdentifier {
                state.events[event.syncKey] = StoredEvent(
                    eventIdentifier: identifier,
                    sourceID: event.sourceID,
                    calendar: event.calendarName,
                    title: resolvedTitle,
                    startISO: iso8601(event.start),
                    endISO: iso8601(event.end)
                )
            }
        }

        let staleEntries = state.events.compactMap { key, value -> DeleteCandidate? in
            guard TimeWeaverCore.shouldDeleteTrackedEvent(
                trackedSourceID: value.sourceID,
                requestedSourceID: sourceIdentity(for: source),
                syncKey: key,
                activeSyncKeys: activeKeys,
                trackedStartISO: value.startISO,
                upcomingOnly: upcomingOnly,
                now: Date(),
                timeZone: TimeZone(identifier: defaultSchedulingTimeZoneIdentifier) ?? .current
            ) else { return nil }
            return DeleteCandidate(
                syncKey: key,
                eventIdentifier: value.eventIdentifier,
                title: value.title,
                startISO: value.startISO,
                endISO: value.endISO
            )
        }.sorted { $0.startISO < $1.startISO }

        var deleteCandidates: [DeleteCandidate] = []
        for candidate in staleEntries {
            if !previewOnly {
                if let event = findStaleEvent(candidate: candidate, calendar: calendar) {
                    try store.remove(event, span: .thisEvent, commit: true)
                }
                state.events.removeValue(forKey: candidate.syncKey)
            }
            if let start = parseFlexibleISO8601(candidate.startISO, timeZone: TimeZone(identifier: defaultSchedulingTimeZoneIdentifier) ?? .current),
               let end = parseFlexibleISO8601(candidate.endISO, timeZone: TimeZone(identifier: defaultSchedulingTimeZoneIdentifier) ?? .current) {
                actions.append(
                    EventAction(
                        status: previewOnly ? "would delete" : "deleted",
                        title: candidate.title,
                        start: start,
                        end: end
                    )
                )
            }
            deleteCandidates.append(candidate)
        }

        return SourceSyncReport(
            sourceItemID: source.id,
            sourceName: source.name,
            bookingID: source.bookingID,
            calendarName: source.calendar,
            parserLabel: extraction.parserLabel,
            parserNotes: extraction.parserNotes,
            reviewRequired: extraction.reviewRequired,
            workbookFingerprint: extraction.workbookFingerprint,
            averageConfidence: extraction.averageConfidence,
            minimumConfidence: extraction.minimumConfidence,
            totalMatchedCount: extraction.allEvents.count,
            syncedMatchedCount: events.count,
            filteredPastCount: extraction.filteredPastCount,
            actions: actions,
            deleteCandidates: deleteCandidates,
            errorMessage: nil
        )
    }

    func revertImageImport(
        record: ImageImportUndoRecord,
        schedulingTimeZoneIdentifier: String
    ) async throws -> String {
        try await ensureAccess()
        let timeZone = TimeZone(identifier: schedulingTimeZoneIdentifier) ?? .current

        guard let calendar = store.calendars(for: .event).first(where: { $0.title == record.calendarName }) else {
            throw AppFailure.calendarNotFound(record.calendarName)
        }

        var state = stateStore.loadState()

        let beforeKeys = Set(record.beforeSnapshot.keys)
        let afterKeys = Set(record.afterSnapshot.keys)
        let createdKeys = afterKeys.subtracting(beforeKeys)
        let deletedKeys = beforeKeys.subtracting(afterKeys)
        let updatedKeys = beforeKeys.intersection(afterKeys).filter {
            record.beforeSnapshot[$0]?.eventIdentifier != record.afterSnapshot[$0]?.eventIdentifier
        }

        var removedCount = 0
        var restoredCount = 0

        for key in createdKeys {
            guard let stored = record.afterSnapshot[key],
                  let start = parseFlexibleISO8601(stored.startISO, timeZone: timeZone),
                  let end = parseFlexibleISO8601(stored.endISO, timeZone: timeZone) else { continue }
            if let ekEvent = findEventForUndo(identifier: stored.eventIdentifier, syncKey: key,
                                              start: start, end: end, calendar: calendar) {
                try store.remove(ekEvent, span: .thisEvent, commit: true)
                removedCount += 1
            }
            state.events.removeValue(forKey: key)
        }

        for key in deletedKeys {
            guard let stored = record.beforeSnapshot[key],
                  let start = parseFlexibleISO8601(stored.startISO, timeZone: timeZone),
                  let end = parseFlexibleISO8601(stored.endISO, timeZone: timeZone),
                  let customURL = primaryEventURL(for: key) else { continue }
            let event = store.makeEvent()
            event.calendar = calendar
            event.title = stored.title
            event.startDate = start
            event.endDate = end
            event.url = customURL
            try store.save(event, span: .thisEvent, commit: true)
            if let identifier = event.eventIdentifier {
                state.events[key] = StoredEvent(
                    eventIdentifier: identifier,
                    sourceID: stored.sourceID,
                    calendar: stored.calendar,
                    title: stored.title,
                    startISO: stored.startISO,
                    endISO: stored.endISO
                )
            }
            restoredCount += 1
        }

        for key in updatedKeys {
            guard let newStored = record.afterSnapshot[key],
                  let oldStored = record.beforeSnapshot[key],
                  let newStart = parseFlexibleISO8601(newStored.startISO, timeZone: timeZone),
                  let newEnd = parseFlexibleISO8601(newStored.endISO, timeZone: timeZone) else { continue }
            if let ekEvent = findEventForUndo(identifier: newStored.eventIdentifier, syncKey: key,
                                              start: newStart, end: newEnd, calendar: calendar) {
                try store.remove(ekEvent, span: .thisEvent, commit: true)
            }
            guard let start = parseFlexibleISO8601(oldStored.startISO, timeZone: timeZone),
                  let end = parseFlexibleISO8601(oldStored.endISO, timeZone: timeZone),
                  let customURL = primaryEventURL(for: key) else {
                state.events.removeValue(forKey: key)
                removedCount += 1
                continue
            }
            let event = store.makeEvent()
            event.calendar = calendar
            event.title = oldStored.title
            event.startDate = start
            event.endDate = end
            event.url = customURL
            try store.save(event, span: .thisEvent, commit: true)
            if let identifier = event.eventIdentifier {
                state.events[key] = StoredEvent(
                    eventIdentifier: identifier,
                    sourceID: oldStored.sourceID,
                    calendar: oldStored.calendar,
                    title: oldStored.title,
                    startISO: oldStored.startISO,
                    endISO: oldStored.endISO
                )
            }
            restoredCount += 1
        }

        stateStore.saveState(state)

        var parts: [String] = ["Import undone."]
        if removedCount > 0 {
            parts.append("Removed \(removedCount) \(removedCount == 1 ? "event" : "events").")
        }
        if restoredCount > 0 {
            parts.append("Restored \(restoredCount) \(restoredCount == 1 ? "event" : "events").")
        }
        return parts.joined(separator: " ")
    }

    func ensureAccess() async throws {
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToEvents()
            if !granted { throw AppFailure.calendarAccessDenied }
        } else {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            if !granted { throw AppFailure.calendarAccessDenied }
        }
    }
}
