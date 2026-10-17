import Foundation
import EventKit

extension CalendarSyncEngine {
    func sync(
        sources: [SourceItem],
        workdayHours: WorkdayHours,
        upcomingOnly: Bool,
        previewOnly: Bool,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        aiApprovals: [AIApprovalRecord],
        schedulingTimeZoneIdentifier: String,
        eventOverrides: [String: EventOverride] = [:],
        cachedExtractions: [UUID: ExtractionResult] = [:]
    ) async throws -> SyncRunResult {
        try await ensureAccess()
        let schedulingTimeZone = TimeZone(identifier: schedulingTimeZoneIdentifier) ?? .current
        let referenceDate = Date()
        var state = stateStore.loadState()
        var reports: [SourceSyncReport] = []
        var lines: [String] = []
        var extractions: [UUID: ExtractionResult] = cachedExtractions

        for source in sources where source.enabled {
            do {
                let extraction: ExtractionResult
                if let cached = cachedExtractions[source.id] {
                    extraction = cached
                } else {
                    let extractor = ReservationExtractor(
                        aiNormalizer: aiNormalizer,
                        localImageParser: localImageParser
                    )
                    extraction = try await extractor.extract(
                        source: source,
                        workdayHours: workdayHours,
                        upcomingOnly: upcomingOnly,
                        parserMode: parserMode,
                        aiConfiguration: aiConfiguration,
                        timeZone: schedulingTimeZone,
                        referenceDate: referenceDate
                    )
                    extractions[source.id] = extraction
                }
                let report = try syncSource(
                    source: source,
                    extraction: extraction,
                    state: &state,
                    upcomingOnly: upcomingOnly,
                    previewOnly: previewOnly,
                    aiApprovals: aiApprovals,
                    eventOverrides: eventOverrides
                )
                reports.append(report)

                lines.append("Source: \(report.sourceName)")
                if report.reviewRequired {
                    lines.append("Approval is required before this source can sync automatically.")
                }
                lines.append("Found \(report.totalMatchedCount) matching \(report.totalMatchedCount == 1 ? "booking" : "bookings").")

                let createStatus = previewOnly ? "would create" : "created"
                let updateStatus = previewOnly ? "would update" : "updated"
                let deleteStatus = previewOnly ? "would delete" : "deleted"
                let createCount = report.actions.filter { $0.status == createStatus }.count
                let updateCount = report.actions.filter { $0.status == updateStatus }.count
                let deleteCount = report.actions.filter { $0.status == deleteStatus }.count
                let unchangedCount = report.actions.filter { $0.status == "unchanged" }.count

                if report.filteredPastCount > 0 {
                    lines.append("Skipped \(report.filteredPastCount) past \(report.filteredPastCount == 1 ? "booking" : "bookings").")
                }

                if createCount > 0 {
                    lines.append(previewOnly ? "Ready to add \(createCount) future \(createCount == 1 ? "event" : "events")." : "Added \(createCount) future \(createCount == 1 ? "event" : "events").")
                }
                if updateCount > 0 {
                    lines.append(previewOnly ? "Ready to update \(updateCount) future \(updateCount == 1 ? "event" : "events")." : "Updated \(updateCount) future \(updateCount == 1 ? "event" : "events").")
                }
                if deleteCount > 0 {
                    lines.append(previewOnly ? "Ready to remove \(deleteCount) future \(deleteCount == 1 ? "event" : "events")." : "Removed \(deleteCount) future \(deleteCount == 1 ? "event" : "events").")
                }
                if createCount == 0 && updateCount == 0 && deleteCount == 0 {
                    if unchangedCount > 0 {
                        lines.append("Future calendar is already up to date.")
                    } else {
                        lines.append(previewOnly ? "No future events need to be added right now." : "No calendar changes were needed.")
                    }
                }

                let changedActions = report.actions.filter { $0.status != "unchanged" }
                if !changedActions.isEmpty {
                    lines.append(previewOnly ? "Planned changes:" : "Completed changes:")
                    for action in changedActions {
                        lines.append("- \(customerFacingInterval(start: action.start, end: action.end))")
                    }
                }
                lines.append("")
            } catch {
                let message = error.localizedDescription
                let report = SourceSyncReport(
                    sourceItemID: source.id,
                    sourceName: source.name,
                    bookingID: source.bookingID,
                    calendarName: source.calendar,
                    parserLabel: "Failed",
                    parserNotes: [],
                    reviewRequired: false,
                    workbookFingerprint: nil,
                    averageConfidence: nil,
                    minimumConfidence: nil,
                    totalMatchedCount: 0,
                    syncedMatchedCount: 0,
                    filteredPastCount: 0,
                    actions: [],
                    deleteCandidates: [],
                    errorMessage: message
                )
                reports.append(report)
                lines.append("Source: \(source.name)")
                lines.append("Could not complete sync for this source.")
                lines.append("Reason: \(message)")
                lines.append("")
            }
        }

        if !previewOnly {
            stateStore.saveState(state)
        }
        return SyncRunResult(reports: reports, outputText: lines.joined(separator: "\n"), extractions: extractions)
    }
}
