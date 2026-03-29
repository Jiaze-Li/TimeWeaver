import Foundation
import AppKit

extension AppModel {
    func refreshCalendars() {
        if ui.isBusy || ui.isCalendarLoading { return }
        ui.isCalendarLoading = true
        ui.status = ui.calendarAccessState == .notDetermined ? "Requesting Calendar access..." : "Loading calendars..."
        Task {
            do {
                let values = try await calendarSyncEngine.calendarNames()
                ui.calendarAccessState = .granted
                ui.calendars = values.isEmpty ? ["Experiment"] : values
                if !ui.calendars.contains(ui.draftCalendar) {
                    ui.draftCalendar = ui.calendars.first ?? "Experiment"
                }
                ui.output = ""
                ui.status = values.isEmpty ? "No calendars found in Apple Calendar" : "Calendars loaded"
            } catch {
                let access = await calendarSyncEngine.calendarAccessState()
                applyCalendarAccessState(access, fallbackMessage: error.localizedDescription)
            }
            ui.isCalendarLoading = false
        }
    }

    func requestCalendarAccess() {
        switch ui.calendarAccessState {
        case .denied, .restricted:
            openCalendarPrivacySettings()
        case .unknown, .notDetermined, .granted:
            refreshCalendars()
        }
    }

    func selectSource(_ item: SourceItem?) {
        guard let item else { return }
        if ui.selectedSourceID != item.id {
            ui.selectedSourceID = item.id
        }
        applyDraftFields(from: item)
        schedulePersist()
    }

    func newSource() {
        ui.selectedSourceID = nil
        ui.draftEnabled = true
        ui.draftName = ""
        ui.draftSource = ""
        ui.draftBookingID = ""
        ui.draftCalendar = ui.calendars.first ?? "Experiment"
        ui.status = "Editing a new source. Fill the fields and click Save."
        schedulePersist()
    }

    func saveCurrentSource() {
        let name = ui.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = ui.draftSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let booking = ui.draftBookingID.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = ui.draftCalendar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !source.isEmpty, !booking.isEmpty, !calendar.isEmpty else {
            ui.status = "Fill in all source fields before saving"
            return
        }

        let item = SourceItem(
            id: ui.selectedSourceID ?? UUID(),
            enabled: ui.draftEnabled,
            name: name,
            source: source,
            bookingID: booking,
            calendar: calendar
        )

        if let selectedSourceID = ui.selectedSourceID,
           let index = ui.sources.firstIndex(where: { $0.id == selectedSourceID }) {
            ui.sources[index] = item
        } else {
            ui.sources.append(item)
        }

        ui.selectedSourceID = item.id
        reconcileSourceStatuses()
        persistSettings()
        ui.status = "Source saved"
    }

    func removeSelectedSource() {
        guard let selectedSourceID = ui.selectedSourceID,
              let index = ui.sources.firstIndex(where: { $0.id == selectedSourceID }) else { return }
        ui.sources.remove(at: index)
        ui.sourceStatuses.removeValue(forKey: selectedSourceID)
        if let next = ui.sources.first {
            selectSource(next)
        } else {
            newSource()
        }
        reconcileSourceStatuses()
        persistSettings()
        ui.status = "Source removed"
    }

    func workdayChanged() {
        schedulePersist()
    }

    func previewAll() {
        runSync(previewOnly: true)
    }

    func syncAll() {
        guard ui.confirmBeforeSync || ui.confirmBeforeDeletion else {
            runSync(previewOnly: false)
            return
        }
        prepareSyncConfirmation()
    }

    func automationChanged() {
        schedulePersist()
        rescheduleTimer()
    }

    func parserSettingsChanged() {
        schedulePersist()
    }

    func draftFieldsChanged() {
        schedulePersist()
    }

    func confirmPendingSync() {
        ui.pendingSyncConfirmation = nil
        runSync(previewOnly: false)
    }

    func cancelPendingSync() {
        ui.pendingSyncConfirmation = nil
        ui.status = "Sync cancelled"
    }

    func aiProviderChanged() {
        switch ui.aiProvider {
        case .openAI, .deepSeek, .kimi, .anthropic, .gemini, .openRouter:
            ui.aiEndpointURL = ui.aiProvider.defaultEndpointURL
            ui.aiModel = ""
        case .custom:
            let presetEndpoints = AIProvider.allCases
                .filter { $0 != .custom }
                .map(\.defaultEndpointURL)
            let presetModels = AIProvider.allCases
                .filter { $0 != .custom }
                .map(\.defaultModel)
            if presetEndpoints.contains(ui.aiEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                ui.aiEndpointURL = ""
            }
            if presetModels.contains(ui.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)) {
                ui.aiModel = ""
            }
        }
        schedulePersist()
    }

    func approvePendingAIReviews() {
        guard !ui.pendingAIReviews.isEmpty else { return }
        let newApprovals = ui.pendingAIReviews.map {
            AIApprovalRecord(
                sourceKey: sourceApprovalKey(for: $0.sourceItemID),
                workbookFingerprint: $0.workbookFingerprint,
                approvedAtISO: iso8601(Date())
            )
        }

        for approval in newApprovals {
            if !ui.aiApprovals.contains(where: { $0.sourceKey == approval.sourceKey && $0.workbookFingerprint == approval.workbookFingerprint }) {
                ui.aiApprovals.append(approval)
            }
        }

        for review in ui.pendingAIReviews {
            if case .review(let matchCount) = ui.sourceStatuses[review.sourceItemID] {
                ui.sourceStatuses[review.sourceItemID] = .success(matchCount: matchCount)
            }
        }
        ui.pendingAIReviews = []
        persistSettings()
        ui.status = "Approved AI layouts for future syncs"
    }

    func openCalendarApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
