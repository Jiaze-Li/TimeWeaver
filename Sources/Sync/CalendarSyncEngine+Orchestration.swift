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
        cachedExtractions: [UUID: ExtractionResult] = [:],
        authorizedDeletionSourceIDs: Set<UUID> = [],
        expectedAutoReviewItems: [AutoReviewChangeItem]? = nil,
        approvedAutoReviewSyncKeys: Set<String>? = nil
    ) async throws -> SyncRunResult {
        let syncStart = ProcessInfo.processInfo.systemUptime
        try await ensureAccess()
        if let approvedAutoReviewSyncKeys {
            guard !previewOnly, let expectedAutoReviewItems,
                  !approvedAutoReviewSyncKeys.isEmpty,
                  approvedAutoReviewSyncKeys.isSubset(of: Set(expectedAutoReviewItems.map(\.syncKey))) else {
                throw AppFailure.syncFailed("Invalid approved booking selection. No changes were applied.")
            }
        }

        // Auto-review approval authorizes only the changes the user actually saw.
        // Verify every proposed mutation before the first calendar write.
        if !previewOnly, let expectedAutoReviewItems {
            let verification = try await sync(
                sources: sources,
                workdayHours: workdayHours,
                upcomingOnly: upcomingOnly,
                previewOnly: true,
                parserMode: parserMode,
                aiConfiguration: aiConfiguration,
                aiApprovals: aiApprovals,
                schedulingTimeZoneIdentifier: schedulingTimeZoneIdentifier,
                eventOverrides: eventOverrides,
                cachedExtractions: cachedExtractions
            )
            guard verification.reports.count == sources.filter(\.enabled).count,
                  !verification.reports.contains(where: { $0.errorMessage != nil || $0.reviewRequired }) else {
                throw AppFailure.syncFailed("Cannot verify reviewed changes. No changes were applied; please review again.")
            }
            let actualItems = buildAutoReviewItems(from: verification.reports, existingState: stateStore.loadState())
            guard actualItems == expectedAutoReviewItems else {
                throw AppFailure.syncFailed("Calendar changes differ from your review. No changes were applied; please review again.")
            }
        }
        let schedulingTimeZone = TimeZone(identifier: schedulingTimeZoneIdentifier) ?? .current
        let referenceDate = Date()
        var state = stateStore.loadState()
        var reports: [SourceSyncReport] = []
        var lines: [String] = []
        var extractions: [UUID: ExtractionResult] = cachedExtractions
        // One read per distinct workbook for this operation only; discarded when sync() returns.
        let workbookSession = WorkbookSession(download: workbookDownloader)
        var calendarCompareSeconds: TimeInterval = 0

        for source in sources where source.enabled {
            let sourceStart = ProcessInfo.processInfo.systemUptime
            do {
                let extractionStart = ProcessInfo.processInfo.systemUptime
                let reusedExtraction = cachedExtractions[source.id] != nil
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
                        workbooks: workbookSession,
                        referenceDate: referenceDate
                    )
                    extractions[source.id] = extraction
                }
                let extractionSeconds = ProcessInfo.processInfo.systemUptime - extractionStart
                let calendarStart = ProcessInfo.processInfo.systemUptime
                let report = try syncSource(
                    source: source,
                    extraction: extraction,
                    state: &state,
                    upcomingOnly: upcomingOnly,
                    previewOnly: previewOnly,
                    aiApprovals: aiApprovals,
                    eventOverrides: eventOverrides,
                    authorizedDeletionSourceIDs: authorizedDeletionSourceIDs,
                    approvedAutoReviewSyncKeys: approvedAutoReviewSyncKeys
                )
                let calendarSeconds = ProcessInfo.processInfo.systemUptime - calendarStart
                calendarCompareSeconds += calendarSeconds
                let sourceSeconds = ProcessInfo.processInfo.systemUptime - sourceStart
                reports.append(report)

                lines.append("Source: \(report.sourceName)")
                if report.reviewRequired {
                    lines.append("Approval is required before this source can sync automatically.")
                }
                lines.append("Found \(report.totalMatchedCount) matching \(report.totalMatchedCount == 1 ? "booking" : "bookings").")
                let formatSeconds: (TimeInterval) -> String = { String(format: "%.2fs", $0) }
                lines.append("Timing: total \(formatSeconds(sourceSeconds)), extraction \(formatSeconds(extractionSeconds)) \(reusedExtraction ? "(cached)" : "(fresh)"), calendar compare/write \(formatSeconds(calendarSeconds)), parser \(report.parserLabel)")
                if !reusedExtraction && !extraction.performanceTimings.isEmpty {
                    let timingOrder = ["download", "unzip", "sharedStrings", "worksheets", "rules", "parser", "merge"]
                    let stages = timingOrder.compactMap { key -> String? in
                        guard let seconds = extraction.performanceTimings[key] else { return nil }
                        return "\(key) \(formatSeconds(seconds))"
                    }
                    let workbookNote = extraction.workbookReused ? "workbook reused from earlier source | " : ""
                    lines.append("  Stages: \(workbookNote)\(stages.joined(separator: " | "))")
                }

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
                lines.append("Timing: failed after \(String(format: "%.2fs", ProcessInfo.processInfo.systemUptime - sourceStart))")
                lines.append("")
            }
        }

        let workbookSummary = await workbookSession.summary()
        if workbookSummary.distinctWorkbooks > 0 {
            let fmt: (TimeInterval) -> String = { String(format: "%.2fs", $0) }
            let t = workbookSummary.timings
            lines.append("Workbooks: \(workbookSummary.distinctWorkbooks) read (\(workbookSummary.downloads) downloaded, \(workbookSummary.parses) parsed), \(workbookSummary.reusedReads) reused")
            lines.append("Workbook time (counted once): download \(fmt(t.download)) | unzip \(fmt(t.unzip)) | sharedStrings \(fmt(t.sharedStrings)) | worksheets \(fmt(t.worksheets))")
        }
        lines.append("Calendar compare/write total: \(String(format: "%.2fs", calendarCompareSeconds))")
        lines.append("Timing overall: \(String(format: "%.2fs", ProcessInfo.processInfo.systemUptime - syncStart))")
        if !previewOnly {
            stateStore.saveState(state)
        }
        return SyncRunResult(reports: reports, outputText: lines.joined(separator: "\n"), extractions: extractions)
    }
}
