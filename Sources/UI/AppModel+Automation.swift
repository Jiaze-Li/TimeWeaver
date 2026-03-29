import Foundation
import AppKit

extension AppModel {
    func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard ui.autoSyncEnabled else { return }
        let minutes = max(Int(ui.autoSyncMinutes) ?? 15, 1)
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.runAutomatedSync()
            }
        }
    }

    private func runAutomatedSync() {
        if ui.isBusy { return }
        if ui.confirmBeforeSync {
            ui.status = "Auto sync is waiting for manual confirmation"
            return
        }
        if ui.confirmBeforeDeletion {
            previewForAutomatedDeletionSafety()
            return
        }
        runSync(previewOnly: false)
    }

    func prepareSyncConfirmation() {
        if ui.isBusy { return }
        let enabledSources = ui.sources.filter(\.enabled)
        guard !enabledSources.isEmpty else {
            ui.status = "Enable at least one source first"
            return
        }

        ui.isBusy = true
        ui.output = ""
        ui.status = "Checking sync changes..."
        setLoadingStatuses(for: enabledSources)
        let syncStartedAt = Date()

        Task {
            do {
                let result = try await calendarSyncEngine.sync(
                    sources: enabledSources,
                    workdayHours: WorkdayHours(
                        start: ui.workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                        end: ui.workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    upcomingOnly: ui.upcomingOnly,
                    previewOnly: true,
                    parserMode: ui.parserMode,
                    aiConfiguration: resolvedAIConfiguration,
                    aiApprovals: ui.aiApprovals,
                    schedulingTimeZoneIdentifier: ui.schedulingTimeZoneIdentifier
                )
                ui.output = result.outputText
                ui.pendingAIReviews = pendingReviews(from: result.reports)
                applySourceStatuses(from: result.reports)

                let hasErrors = result.reports.contains { $0.errorMessage != nil }
                if hasErrors {
                    ui.status = "Fix source errors before syncing"
                } else if !ui.pendingAIReviews.isEmpty {
                    ui.status = "Approve AI layouts before syncing"
                } else if let confirmation = buildSyncConfirmation(from: result.reports) {
                    ui.pendingSyncConfirmation = confirmation
                    ui.status = "Review sync changes"
                } else if hasNonDeleteChanges(in: result.reports) {
                    ui.status = "Applying sync changes..."
                    ui.isBusy = false
                    runSync(previewOnly: false)
                    return
                } else {
                    ui.status = "No changes to sync\nSync at \(syncTimestampString(syncStartedAt))"
                }
            } catch {
                ui.output = error.localizedDescription
                ui.pendingAIReviews = []
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

        let shouldPrompt = ui.confirmBeforeSync
            ? (createCount + updateCount + deleteCount > 0)
            : (ui.confirmBeforeDeletion && deleteCount > 0)
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
        return PendingSyncConfirmation(message: lines.joined(separator: "\n"))
    }

    private func hasNonDeleteChanges(in reports: [SourceSyncReport]) -> Bool {
        reports.contains { report in
            report.actions.contains { action in
                ["would create", "would update"].contains(action.status)
            }
        }
    }

    private func previewForAutomatedDeletionSafety() {
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
                let result = try await calendarSyncEngine.sync(
                    sources: enabledSources,
                    workdayHours: WorkdayHours(
                        start: ui.workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                        end: ui.workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    upcomingOnly: ui.upcomingOnly,
                    previewOnly: true,
                    parserMode: ui.parserMode,
                    aiConfiguration: resolvedAIConfiguration,
                    aiApprovals: ui.aiApprovals,
                    schedulingTimeZoneIdentifier: ui.schedulingTimeZoneIdentifier
                )
                ui.output = result.outputText
                ui.pendingAIReviews = pendingReviews(from: result.reports)
                applySourceStatuses(from: result.reports)

                let deleteCount = result.reports.reduce(0) { count, report in
                    count + report.actions.filter { $0.status == "would delete" }.count
                }
                let hasErrors = result.reports.contains { $0.errorMessage != nil }
                if hasErrors {
                    ui.status = "Auto sync found source errors"
                } else if !ui.pendingAIReviews.isEmpty {
                    ui.status = "Auto sync is waiting for AI approval"
                } else if deleteCount > 0 {
                    ui.status = "Auto sync found removed events waiting for manual confirmation"
                } else if hasNonDeleteChanges(in: result.reports) {
                    ui.isBusy = false
                    runSync(previewOnly: false)
                    return
                } else {
                    ui.status = "Auto sync checked: no changes"
                }
            } catch {
                ui.output = error.localizedDescription
                clearLoadingStatuses()
                ui.status = error.localizedDescription
            }
            ui.isBusy = false
        }
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
