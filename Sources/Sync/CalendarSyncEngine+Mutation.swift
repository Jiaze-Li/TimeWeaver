import Foundation
import EventKit
#if canImport(TimeWeaverCore)
import TimeWeaverCore
#endif

extension CalendarSyncEngine {
    func syncSource(
        source: SourceItem,
        extraction: ExtractionResult,
        state: inout SyncState,
        upcomingOnly: Bool,
        previewOnly: Bool,
        aiApprovals: [AIApprovalRecord],
        eventOverrides: [String: EventOverride] = [:],
        authorizedDeletionSourceIDs: Set<UUID> = []
    ) throws -> SourceSyncReport {
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == source.calendar }) else {
            throw AppFailure.calendarNotFound(source.calendar)
        }

        if !previewOnly, extraction.reviewRequired {
            let sourceKey = sourceIdentity(for: source)
            let legacyKey = legacySourceIdentity(for: source)
            let isApproved = aiApprovals.contains {
                ($0.sourceKey == sourceKey || $0.sourceKey == legacyKey) && $0.workbookFingerprint == extraction.workbookFingerprint
            }
            if !isApproved {
                throw AppFailure.syncFailed("AI parse needs review first. Run Preview, then click Approve AI before Sync.")
            }
        }

        var actions: [EventAction] = []
        let events = extraction.filteredEvents
        var activeKeys = Set(events.map(\.syncKey))
        let activeLegacyKeys = Set(events.compactMap(\.legacySyncKey))
        activeKeys.formUnion(activeLegacyKeys)

        for event in events {
            let override = eventOverrides[event.syncKey]
            let resolvedTitle = override?.title ?? event.sourceName
            let resolvedStart = override?.start ?? event.start
            let resolvedEnd = override?.end ?? event.end

            guard TimeWeaverCore.validateTimeInterval(start: resolvedStart, end: resolvedEnd) else {
                throw AppFailure.invalidTime("Start time must be before end time for '\(resolvedTitle)'.")
            }

            let customURL = primaryEventURL(for: event.syncKey)!
            var matchedKey = event.syncKey
            var existingRecord = state.events[event.syncKey]
            if existingRecord == nil, let legacyKey = event.legacySyncKey {
                if let legacyRecord = state.events[legacyKey] {
                    existingRecord = legacyRecord
                    matchedKey = legacyKey
                }
            }
            if existingRecord == nil {
                let startISOStr = iso8601(resolvedStart)
                let endISOStr = iso8601(resolvedEnd)
                if let (timeMatchedKey, timeMatchedRecord) = state.events.first(where: { k, v in
                    TimeWeaverCore.matchesSourceIdentity(
                        trackedSourceID: v.sourceID,
                        currentSourceID: sourceIdentity(for: source),
                        legacySourceID: legacySourceIdentity(for: source)
                    ) && v.startISO == startISOStr && v.endISO == endISOStr
                }) {
                    existingRecord = timeMatchedRecord
                    matchedKey = timeMatchedKey
                }
            }
            activeKeys.insert(matchedKey)

            let existingEvent = findExistingEvent(for: event, stateRecord: existingRecord, calendar: calendar, customURL: customURL)
            let oldSignature = existingEvent.map(eventSignature) ?? ""
            let calendarChanged = existingEvent != nil && existingEvent?.calendar?.title != calendar.title

            let target: EKEvent
            var oldEventToDelete: EKEvent? = nil
            if previewOnly {
                // In preview mode, do not mutate existing EKEvent objects in memory
                let newSignature = proposedEventSignature(
                    title: resolvedTitle,
                    start: resolvedStart,
                    end: resolvedEnd,
                    isAllDay: event.isAllDay,
                    notes: event.sourceLink,
                    url: customURL,
                    calendarTitle: calendar.title
                )
                let mutation = TimeWeaverCore.determineUpsertMutation(
                    hasExistingEvent: existingEvent != nil && !calendarChanged,
                    oldSignature: oldSignature,
                    newSignature: newSignature
                )
                let status: String
                if mutation == .create || calendarChanged {
                    status = "would create"
                } else if mutation == .update {
                    status = "would update"
                } else {
                    status = "unchanged"
                }
                actions.append(EventAction(status: status, title: resolvedTitle, start: resolvedStart, end: resolvedEnd, syncKey: event.syncKey))
            } else {
                if let existing = existingEvent {
                    if calendarChanged {
                        // CalDAV accounts often disallow moving events across calendars directly.
                        // Save the new event to the new calendar first, then remove the old one.
                        oldEventToDelete = existing
                        target = store.makeEvent()
                    } else {
                        target = existing
                    }
                } else {
                    target = store.makeEvent()
                }

                target.calendar = calendar
                target.title = resolvedTitle
                target.startDate = resolvedStart
                target.endDate = resolvedEnd
                target.isAllDay = event.isAllDay
                target.notes = event.sourceLink
                target.url = customURL

                let newSignature = eventSignature(target)
                let mutation = TimeWeaverCore.determineUpsertMutation(
                    hasExistingEvent: existingEvent != nil && !calendarChanged,
                    oldSignature: oldSignature,
                    newSignature: newSignature
                )
                let status: String
                if mutation == .create || calendarChanged {
                    status = "created"
                    // Safe cross-calendar migration order: Save new event first
                    try store.save(target, span: .thisEvent, commit: true)
                    if let oldToDel = oldEventToDelete {
                        do {
                            try store.remove(oldToDel, span: .thisEvent, commit: true)
                        } catch let removeError {
                            // If removing old event fails, attempt to rollback the newly created event
                            do {
                                try store.remove(target, span: .thisEvent, commit: true)
                            } catch let rollbackError {
                                // Both failed: report explicit failure with identifiers so it can be investigated and not ignored
                                let targetID = target.eventIdentifier ?? "unknown"
                                let oldID = oldToDel.eventIdentifier ?? "unknown"
                                throw AppFailure.syncFailed("Cross-calendar migration failed: could not remove old event '\(oldID)' (\(removeError.localizedDescription)), and rollback removal of new event '\(targetID)' also failed (\(rollbackError.localizedDescription)).")
                            }
                            throw removeError
                        }
                    }
                } else if mutation == .update {
                    status = "updated"
                    try store.save(target, span: .thisEvent, commit: true)
                } else {
                    status = "unchanged"
                }

                actions.append(EventAction(status: status, title: resolvedTitle, start: resolvedStart, end: resolvedEnd, syncKey: event.syncKey))
                if let identifier = target.eventIdentifier {
                    if matchedKey != event.syncKey {
                        state.events.removeValue(forKey: matchedKey)
                    }
                    if let legacyKey = event.legacySyncKey, legacyKey != event.syncKey {
                        state.events.removeValue(forKey: legacyKey)
                    }
                    state.events[event.syncKey] = StoredEvent(
                        eventIdentifier: identifier,
                        sourceID: event.sourceID,
                        calendar: event.calendarName,
                        title: resolvedTitle,
                        startISO: iso8601(resolvedStart),
                        endISO: iso8601(resolvedEnd)
                    )
                }
            }
        }

        let staleEntries = state.events.compactMap { key, value -> DeleteCandidate? in
            guard TimeWeaverCore.shouldDeleteTrackedEvent(
                trackedSourceID: value.sourceID,
                requestedSourceID: sourceIdentity(for: source),
                legacySourceID: legacySourceIdentity(for: source),
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

        let isSuspicious = TimeWeaverCore.isDeletionSuspicious(
            trackedCount: staleEntries.count,
            extractedCount: events.count,
            reviewRequired: extraction.reviewRequired
        )

        let isDeletionAuthorized = !isSuspicious || authorizedDeletionSourceIDs.contains(source.id)

        var deleteCandidates: [DeleteCandidate] = []
        for candidate in staleEntries {
            let start = parseFlexibleISO8601(candidate.startISO, timeZone: TimeZone(identifier: defaultSchedulingTimeZoneIdentifier) ?? .current)
            let end = parseFlexibleISO8601(candidate.endISO, timeZone: TimeZone(identifier: defaultSchedulingTimeZoneIdentifier) ?? .current)

            if previewOnly {
                // In preview mode, always record deletion candidate and proposed deletion action
                // so the user can inspect planned deletions and confirm via the UI confirmation dialog.
                deleteCandidates.append(candidate)
                if let start, let end {
                    actions.append(
                        EventAction(
                            status: "would delete",
                            title: candidate.title,
                            start: start,
                            end: end,
                            syncKey: candidate.syncKey
                        )
                    )
                }
            } else {
                // In execution mode (!previewOnly), enforce deletion safety:
                if !isDeletionAuthorized {
                    // Unauthorized suspicious deletions are blocked from execution
                    if let start, let end {
                        actions.append(
                            EventAction(
                                status: "deletion rejected: suspicious",
                                title: candidate.title,
                                start: start,
                                end: end,
                                syncKey: candidate.syncKey
                            )
                        )
                    }
                } else {
                    if let event = findStaleEvent(candidate: candidate, calendar: calendar) {
                        try store.remove(event, span: .thisEvent, commit: true)
                    }
                    state.events.removeValue(forKey: candidate.syncKey)
                    deleteCandidates.append(candidate)
                    if let start, let end {
                        actions.append(
                            EventAction(
                                status: "deleted",
                                title: candidate.title,
                                start: start,
                                end: end,
                                syncKey: candidate.syncKey
                            )
                        )
                    }
                }
            }
        }

        var parserNotes = extraction.parserNotes
        if isSuspicious {
            if isDeletionAuthorized {
                parserNotes.append("Suspicious deletion authorized: \(staleEntries.count) events removed.")
            } else {
                parserNotes.append("Deletion protection triggered: 0 bookings matched, but \(staleEntries.count) events were previously synced. Stale events were preserved.")
            }
        }

        return SourceSyncReport(
            sourceItemID: source.id,
            sourceName: source.name,
            bookingID: source.bookingID,
            calendarName: source.calendar,
            parserLabel: extraction.parserLabel,
            parserNotes: parserNotes,
            reviewRequired: extraction.reviewRequired,
            workbookFingerprint: extraction.workbookFingerprint,
            averageConfidence: extraction.averageConfidence,
            minimumConfidence: extraction.minimumConfidence,
            totalMatchedCount: extraction.allEvents.count,
            syncedMatchedCount: events.count,
            filteredPastCount: extraction.filteredPastCount,
            actions: actions,
            deleteCandidates: deleteCandidates,
            isSuspiciousDeletion: isSuspicious,
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
            guard let b = record.beforeSnapshot[$0], let a = record.afterSnapshot[$0] else { return false }
            return b.title != a.title || b.startISO != a.startISO || b.endISO != a.endISO
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
            stateStore.saveState(state)
        }

        for key in deletedKeys {
            guard let stored = record.beforeSnapshot[key],
                  let start = parseFlexibleISO8601(stored.startISO, timeZone: timeZone),
                  let end = parseFlexibleISO8601(stored.endISO, timeZone: timeZone),
                  let customURL = primaryEventURL(for: key) else { continue }

            let matches = findMatchingEventsForUndo(syncKey: key, start: start, end: end, calendar: calendar)
            if matches.count > 1 {
                throw AppFailure.syncFailed("Cannot safely undo event '\(stored.title)': found \(matches.count) matching calendar events with key '\(key)'.")
            }

            if let existing = matches.first {
                // Event is already present in calendar (e.g. from previous partial undo attempt); reuse in-place
                existing.title = stored.title
                existing.startDate = start
                existing.endDate = end
                existing.url = customURL
                try store.save(existing, span: .thisEvent, commit: true)
                if let identifier = existing.eventIdentifier {
                    state.events[key] = StoredEvent(
                        eventIdentifier: identifier,
                        sourceID: stored.sourceID,
                        calendar: stored.calendar,
                        title: stored.title,
                        startISO: stored.startISO,
                        endISO: stored.endISO
                    )
                    stateStore.saveState(state)
                }
                restoredCount += 1
            } else {
                // Not restored yet; create new event
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
                    stateStore.saveState(state)
                }
                restoredCount += 1
            }
        }

        for key in updatedKeys {
            guard let newStored = record.afterSnapshot[key],
                  let oldStored = record.beforeSnapshot[key],
                  let newStart = parseFlexibleISO8601(newStored.startISO, timeZone: timeZone),
                  let newEnd = parseFlexibleISO8601(newStored.endISO, timeZone: timeZone),
                  let oldStart = parseFlexibleISO8601(oldStored.startISO, timeZone: timeZone),
                  let oldEnd = parseFlexibleISO8601(oldStored.endISO, timeZone: timeZone),
                  let customURL = primaryEventURL(for: key) else { continue }

            if let ekEvent = findEventForUndo(identifier: newStored.eventIdentifier, syncKey: key,
                                              start: newStart, end: newEnd, calendar: calendar) {
                // Update in-place to avoid recreation or duplicate events
                ekEvent.title = oldStored.title
                ekEvent.startDate = oldStart
                ekEvent.endDate = oldEnd
                ekEvent.url = customURL
                try store.save(ekEvent, span: .thisEvent, commit: true)
                state.events[key] = StoredEvent(
                    eventIdentifier: ekEvent.eventIdentifier ?? oldStored.eventIdentifier,
                    sourceID: oldStored.sourceID,
                    calendar: oldStored.calendar,
                    title: oldStored.title,
                    startISO: oldStored.startISO,
                    endISO: oldStored.endISO
                )
                stateStore.saveState(state)
                restoredCount += 1
            } else {
                let matches = findMatchingEventsForUndo(syncKey: key, start: oldStart, end: oldEnd, calendar: calendar)
                if matches.count > 1 {
                    throw AppFailure.syncFailed("Cannot safely undo updated event '\(oldStored.title)': found \(matches.count) matching calendar events with key '\(key)'.")
                }
                if let existing = matches.first {
                    existing.title = oldStored.title
                    existing.startDate = oldStart
                    existing.endDate = oldEnd
                    existing.url = customURL
                    try store.save(existing, span: .thisEvent, commit: true)
                    if let identifier = existing.eventIdentifier {
                        state.events[key] = StoredEvent(
                            eventIdentifier: identifier,
                            sourceID: oldStored.sourceID,
                            calendar: oldStored.calendar,
                            title: oldStored.title,
                            startISO: oldStored.startISO,
                            endISO: oldStored.endISO
                        )
                        stateStore.saveState(state)
                    }
                    restoredCount += 1
                } else {
                    // Event was not found; recreate it
                    let event = store.makeEvent()
                    event.calendar = calendar
                    event.title = oldStored.title
                    event.startDate = oldStart
                    event.endDate = oldEnd
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
                        stateStore.saveState(state)
                    }
                    restoredCount += 1
                }
            }
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
