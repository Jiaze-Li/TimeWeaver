import Foundation

extension AppModel {
    func runtimeStatus(for item: SourceItem) -> SourceRuntimeStatus {
        ui.sourceStatuses[item.id] ?? .idle
    }

    func schedulePersist(delayNanoseconds: UInt64 = 250_000_000) {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.settingsSnapshot()
            self.settingsCoordinator.persistIfNeeded(
                settings: snapshot.settings,
                encodedData: snapshot.data,
                aiAPIKey: self.ui.aiAPIKey
            )
        }
    }

    func persistSettings() {
        let snapshot = settingsSnapshot()
        settingsCoordinator.persistIfNeeded(
            settings: snapshot.settings,
            encodedData: snapshot.data,
            aiAPIKey: ui.aiAPIKey
        )
    }

    func settingsSnapshot() -> (settings: AppSettings, data: Data) {
        let settings = AppSettings(
            sources: ui.sources,
            workdayHours: WorkdayHours(
                start: ui.workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                end: ui.workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            schedulingTimeZoneIdentifier: ui.schedulingTimeZoneIdentifier,
            autoSyncEnabled: ui.autoSyncEnabled,
            autoSyncMinutes: max(Int(ui.autoSyncMinutes) ?? 15, 1),
            upcomingOnly: ui.upcomingOnly,
            confirmBeforeSync: ui.confirmBeforeSync,
            confirmBeforeDeletion: ui.confirmBeforeDeletion,
            menuBarModeEnabled: ui.menuBarModeEnabled,
            parserMode: ui.parserMode,
            aiParser: AIParserSettings(
                provider: ui.aiProvider,
                endpointURL: ui.aiEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: ui.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            aiApprovals: ui.aiApprovals,
            lastDraft: currentDraftState()
        )
        let data = (try? JSONEncoder().encode(settings)) ?? Data()
        return (settings, data)
    }

    func reconcileSourceStatuses() {
        var next = ui.sourceStatuses.filter { key, _ in ui.sources.contains(where: { $0.id == key }) }
        for item in ui.sources where next[item.id] == nil {
            next[item.id] = .idle
        }
        ui.sourceStatuses = next
    }

    func setLoadingStatuses(for activeSources: [SourceItem]) {
        reconcileSourceStatuses()
        let activeIDs = Set(activeSources.map(\.id))
        for item in ui.sources {
            if activeIDs.contains(item.id) {
                ui.sourceStatuses[item.id] = .loading
            } else if !item.enabled {
                ui.sourceStatuses[item.id] = .idle
            }
        }
    }

    func clearLoadingStatuses() {
        reconcileSourceStatuses()
        for item in ui.sources where ui.sourceStatuses[item.id] == .loading {
            ui.sourceStatuses[item.id] = .idle
        }
    }

    func applySourceStatuses(from reports: [SourceSyncReport]) {
        reconcileSourceStatuses()
        for report in reports {
            if let message = report.errorMessage {
                ui.sourceStatuses[report.sourceItemID] = .failure(message)
            } else if report.reviewRequired {
                ui.sourceStatuses[report.sourceItemID] = .review(matchCount: report.totalMatchedCount)
            } else {
                ui.sourceStatuses[report.sourceItemID] = .success(matchCount: report.totalMatchedCount)
            }
        }
    }

    var resolvedAIConfiguration: AIServiceConfiguration? {
        let provider = ui.aiProvider
        let endpoint = ui.aiEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = ui.aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = ui.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEndpoint = endpoint.isEmpty ? provider.defaultEndpointURL : endpoint
        guard !apiKey.isEmpty, !resolvedEndpoint.isEmpty, let url = URL(string: resolvedEndpoint) else {
            return nil
        }
        if provider == .custom && model.isEmpty {
            return nil
        }
        return AIServiceConfiguration(provider: provider, endpointURL: url, apiKey: apiKey, model: model)
    }

    func pendingReviews(from reports: [SourceSyncReport]) -> [PendingAIReview] {
        reports.compactMap { report in
            guard report.reviewRequired, let workbookFingerprint = report.workbookFingerprint else {
                return nil
            }
            return PendingAIReview(
                sourceItemID: report.sourceItemID,
                sourceName: report.sourceName,
                workbookFingerprint: workbookFingerprint,
                parserLabel: report.parserLabel,
                averageConfidence: report.averageConfidence,
                minimumConfidence: report.minimumConfidence
            )
        }
    }

    func sourceApprovalKey(for sourceID: UUID) -> String {
        guard let item = ui.sources.first(where: { $0.id == sourceID }) else {
            return sourceID.uuidString
        }
        return sourceIdentity(for: item)
    }
}
