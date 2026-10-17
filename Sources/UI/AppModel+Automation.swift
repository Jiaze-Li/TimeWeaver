import Foundation
import AppKit
import SwiftUI


extension AppModel {
    func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard ui.autoSyncEnabled else { return }
        let minutes = max(Int(ui.autoSyncMinutes) ?? defaultAutoSyncMinutes, 1)
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.runAutomatedSync()
            }
        }
    }

    private func runAutomatedSync() {
        triggerAutomatedSync()
    }

    func prepareSyncConfirmation() {
        if ui.isBusy { return }
        let enabledSources = ui.sources.filter(\.enabled)
        guard !enabledSources.isEmpty else {
            ui.status = "Enable at least one source first"
            return
        }

        beginBusyTask(status: "Checking sync changes...")
        setLoadingStatuses(for: enabledSources)
        let syncStartedAt = Date()

        Task {
            do {
                let result = try await performSync(
                    sources: enabledSources,
                    upcomingOnly: ui.upcomingOnly,
                    previewOnly: true
                )
                ui.output = result.outputText
                ui.pendingAIReviews = pendingReviews(from: result.reports)
                applySourceStatuses(from: result.reports)

                let workdayHours = "\(ui.workdayStart)-\(ui.workdayEnd)"
                let hasErrors = result.reports.contains { $0.errorMessage != nil }
                if hasErrors {
                    ui.pendingSyncPlan = nil
                    ui.status = "Fix source errors before syncing"
                } else if !ui.pendingAIReviews.isEmpty {
                    ui.pendingSyncPlan = nil
                    ui.status = "Approve AI layouts before syncing"
                } else if let confirmation = buildSyncConfirmation(from: result.reports) {
                    ui.pendingSyncPlan = SyncPlan(
                        reports: result.reports,
                        extractions: result.extractions,
                        outputText: result.outputText,
                        sources: enabledSources,
                        upcomingOnly: ui.upcomingOnly,
                        workdayHours: workdayHours
                    )
                    ui.pendingSyncConfirmation = confirmation
                    ui.status = "Review sync changes"
                } else if hasNonDeleteChanges(in: result.reports) {
                    ui.pendingSyncPlan = SyncPlan(
                        reports: result.reports,
                        extractions: result.extractions,
                        outputText: result.outputText,
                        sources: enabledSources,
                        upcomingOnly: ui.upcomingOnly,
                        workdayHours: workdayHours
                    )
                    ui.status = "Applying sync changes..."
                    ui.isBusy = false
                    runSync(previewOnly: false)
                    return
                } else {
                    ui.pendingSyncPlan = nil
                    ui.status = "No changes to sync\nSync at \(syncTimestampString(syncStartedAt))"
                }
            } catch {
                ui.output = error.localizedDescription
                ui.pendingAIReviews = []
                ui.pendingSyncPlan = nil
                clearLoadingStatuses()
                ui.status = error.localizedDescription
            }
            ui.isBusy = false
        }
    }

    private func buildSyncConfirmation(from reports: [SourceSyncReport]) -> PendingSyncConfirmation? {
        let createCount = reports.reduce(0) { count, report in
            count + report.actions.filter { $0.status == "would create" }.count
        }
        let updateCount = reports.reduce(0) { count, report in
            count + report.actions.filter { $0.status == "would update" }.count
        }
        let deleteCount = reports.reduce(0) { count, report in
            count + report.actions.filter { $0.status == "would delete" }.count
        }

        let suspiciousReports = reports.filter(\.isSuspiciousDeletion)
        let hasSuspiciousDeletion = !suspiciousReports.isEmpty

        let shouldPrompt = hasSuspiciousDeletion
            || (ui.confirmBeforeSync ? (createCount + updateCount + deleteCount > 0) : (ui.confirmBeforeDeletion && deleteCount > 0))
        guard shouldPrompt else {
            return nil
        }

        let changedSources = reports.compactMap { report -> String? in
            let changeCount = report.actions.filter {
                ["would create", "would update", "would delete"].contains($0.status)
            }.count
            return changeCount > 0 ? report.sourceName : nil
        }

        var lines: [String] = []
        if hasSuspiciousDeletion {
            let names = suspiciousReports.map(\.sourceName).joined(separator: ", ")
            lines.append("⚠️ UNUSUAL DELETION WARNING:")
            lines.append("Source '\(names)' matched 0 bookings, but events are currently scheduled in your calendar.")
            lines.append("Please verify that appointments were intentionally removed from the source.")
            lines.append("")
        }
        lines.append("This sync will apply these calendar changes:")
        lines.append("Add: \(createCount)")
        lines.append("Update: \(updateCount)")
        lines.append("Remove: \(deleteCount)")
        if !changedSources.isEmpty {
            lines.append("")
            lines.append("Sources: \(changedSources.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("Continue?")
        let authorizedIDs = Set(suspiciousReports.map(\.sourceItemID))
        return PendingSyncConfirmation(message: lines.joined(separator: "\n"), authorizedDeletionSourceIDs: authorizedIDs)
    }

    private func hasNonDeleteChanges(in reports: [SourceSyncReport]) -> Bool {
        reports.contains { report in
            report.actions.contains { action in
                ["would create", "would update"].contains(action.status)
            }
        }
    }

    func triggerAutomatedSync() {
        if ui.isBusy { return }
        checkAndReviewCalendarChanges()
    }

    func checkAndReviewCalendarChanges() {
        if ui.isBusy { return }
        let enabledSources = ui.sources.filter(\.enabled)
        guard !enabledSources.isEmpty else {
            ui.status = "Enable at least one source first"
            return
        }

        ui.isBusy = true
        ui.status = "Checking automated sync changes..."
        setLoadingStatuses(for: enabledSources)

        Task {
            do {
                let result = try await performSync(
                    sources: enabledSources,
                    upcomingOnly: ui.upcomingOnly,
                    previewOnly: true
                )
                ui.output = result.outputText
                ui.pendingAIReviews = pendingReviews(from: result.reports)
                applySourceStatuses(from: result.reports)

                let hasErrors = result.reports.contains { $0.errorMessage != nil }
                if hasErrors {
                    ui.status = "Auto sync found source errors"
                    ui.isBusy = false
                    return
                }
                if !ui.pendingAIReviews.isEmpty {
                    ui.status = "Auto sync is waiting for AI approval"
                    ui.isBusy = false
                    return
                }

                let items = buildAutoReviewChangeItems(from: result.reports)
                if items.isEmpty {
                    ui.status = "Auto sync checked: no changes"
                    ui.isBusy = false
                    return
                }

                let fingerprint = computeChangeFingerprint(for: items)
                if fingerprint == dismissedChangeFingerprint {
                    ui.status = "Auto sync checked: proposed changes already reviewed and dismissed"
                    ui.isBusy = false
                    return
                }

                let suspiciousReports = result.reports.filter(\.isSuspiciousDeletion)
                let authorizedIDs = Set(suspiciousReports.map(\.sourceItemID))
                let workdayHours = "\(ui.workdayStart)-\(ui.workdayEnd)"
                let plan = SyncPlan(
                    reports: result.reports,
                    extractions: result.extractions,
                    outputText: result.outputText,
                    sources: enabledSources,
                    upcomingOnly: ui.upcomingOnly,
                    workdayHours: workdayHours
                )

                let review = PendingAutoReview(
                    items: items,
                    fingerprint: fingerprint,
                    plan: plan,
                    authorizedDeletionSourceIDs: authorizedIDs
                )

                ui.pendingSyncPlan = plan
                ui.isBusy = false
                presentAutoReview(review)
            } catch {
                ui.output = error.localizedDescription
                clearLoadingStatuses()
                ui.status = error.localizedDescription
                ui.isBusy = false
            }
        }
    }


    func buildAutoReviewChangeItems(from reports: [SourceSyncReport], existingState: SyncState? = nil) -> [AutoReviewChangeItem] {
        buildAutoReviewItems(from: reports, existingState: existingState ?? SettingsStore.loadState())
    }




    func computeChangeFingerprint(for items: [AutoReviewChangeItem]) -> String {
        TimeWeaverCore.computeChangeFingerprint(
            items: items.map { item in
                (
                    sourceName: item.sourceName,
                    calendarName: item.calendarName,
                    status: item.status,
                    title: item.title,
                    oldStartTimestamp: item.oldStart?.timeIntervalSince1970 ?? 0,
                    oldEndTimestamp: item.oldEnd?.timeIntervalSince1970 ?? 0,
                    newStartTimestamp: item.newStart?.timeIntervalSince1970 ?? 0,
                    newEndTimestamp: item.newEnd?.timeIntervalSince1970 ?? 0,
                    syncKey: item.syncKey
                )
            }
        )
    }

    func presentAutoReview(_ review: PendingAutoReview) {
        ui.pendingAutoReview = review
        ui.status = "Review calendar changes"

        if autoReviewWindowController == nil {
            let contentView = AutoReviewWindowView(review: review).environmentObject(self)
            let hosting = NSHostingController(rootView: contentView)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Review Calendar Changes"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 580, height: 380))
            window.center()
            window.isReleasedWhenClosed = false

            final class WindowCloseDelegate: NSObject, NSWindowDelegate {
                weak var model: AppModel?
                init(model: AppModel) { self.model = model }
                func windowWillClose(_ notification: Notification) {
                    model?.handleAutoReviewWindowClosed()
                }
            }

            let delegate = WindowCloseDelegate(model: self)
            window.delegate = delegate
            objc_setAssociatedObject(window, "WindowCloseDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)

            autoReviewWindowController = NSWindowController(window: window)
        } else if let window = autoReviewWindowController?.window {
            let contentView = AutoReviewWindowView(review: review).environmentObject(self)
            window.contentViewController = NSHostingController(rootView: contentView)
        }

        autoReviewWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func acceptAutoReview() {
        guard let review = ui.pendingAutoReview else { return }
        closeAutoReviewWindow()
        dismissedChangeFingerprint = nil
        ui.pendingSyncPlan = review.plan
        runSync(previewOnly: false, authorizedDeletionSourceIDs: review.authorizedDeletionSourceIDs)
    }

    func ignoreAutoReview() {
        guard let review = ui.pendingAutoReview else { return }
        dismissedChangeFingerprint = review.fingerprint
        closeAutoReviewWindow()
        invalidatePendingSyncPlan()
        ui.status = "Auto sync changes ignored"
    }

    func handleAutoReviewWindowClosed() {
        if let review = ui.pendingAutoReview {
            dismissedChangeFingerprint = review.fingerprint
            ui.pendingAutoReview = nil
            invalidatePendingSyncPlan()
            ui.status = "Auto sync changes ignored"
        }
    }

    func closeAutoReviewWindow() {
        ui.pendingAutoReview = nil
        autoReviewWindowController?.close()
    }

    func runLaunchAutomationIfNeeded() {
        guard let launchAutomation else { return }
        let enabledSources = (launchAutomation.sources ?? ui.sources).filter(\.enabled)
        guard !enabledSources.isEmpty else {
            writeLaunchAutomationOutput(
                "ERROR: No enabled sources are available for launch automation.\n",
                to: launchAutomation.outputPath,
                terminateAfterCompletion: launchAutomation.terminateAfterCompletion
            )
            return
        }

        Task {
            let previewOnly = launchAutomation.action == .preview
            let effectiveWorkdayHours = launchAutomation.workdayHours ?? WorkdayHours(
                start: ui.workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                end: ui.workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let effectiveUpcomingOnly = launchAutomation.upcomingOnly ?? ui.upcomingOnly
            let effectiveParserMode = launchAutomation.parserMode ?? ui.parserMode
            let effectiveAIConfiguration = launchAutomationAIConfiguration(launchAutomation) ?? resolvedAIConfiguration
            do {
                let result = try await calendarSyncEngine.sync(
                    sources: enabledSources,
                    workdayHours: effectiveWorkdayHours,
                    upcomingOnly: effectiveUpcomingOnly,
                    previewOnly: previewOnly,
                    parserMode: effectiveParserMode,
                    aiConfiguration: effectiveAIConfiguration,
                    aiApprovals: ui.aiApprovals,
                    schedulingTimeZoneIdentifier: ui.schedulingTimeZoneIdentifier
                )
                writeLaunchAutomationOutput(
                    result.outputText,
                    to: launchAutomation.outputPath,
                    terminateAfterCompletion: launchAutomation.terminateAfterCompletion
                )
            } catch {
                writeLaunchAutomationOutput(
                    "ERROR: \(error.localizedDescription)\n",
                    to: launchAutomation.outputPath,
                    terminateAfterCompletion: launchAutomation.terminateAfterCompletion
                )
            }
        }
    }

    private func launchAutomationAIConfiguration(_ launchAutomation: LaunchAutomation) -> AIServiceConfiguration? {
        let provider = launchAutomation.aiProvider
            ?? inferAIProvider(fromEndpoint: launchAutomation.aiEndpointURL ?? "")
        let endpoint = launchAutomation.aiEndpointURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = launchAutomation.aiModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apiKey = launchAutomation.aiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedEndpoint = endpoint.isEmpty ? provider.defaultEndpointURL : endpoint
        guard !apiKey.isEmpty, !resolvedEndpoint.isEmpty, let url = URL(string: resolvedEndpoint) else {
            return nil
        }
        if provider == .custom && model.isEmpty {
            return nil
        }
        return AIServiceConfiguration(provider: provider, endpointURL: url, apiKey: apiKey, model: model)
    }

    private func writeLaunchAutomationOutput(_ text: String, to path: String, terminateAfterCompletion: Bool) {
        let outputURL = URL(fileURLWithPath: path)
        do {
            try text.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
        }

        guard terminateAfterCompletion else { return }
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }
}
