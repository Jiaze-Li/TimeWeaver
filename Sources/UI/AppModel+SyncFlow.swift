import Foundation
import AppKit

extension AppModel {
    func undoLastImageImport() {
        guard let record = ui.lastImageImportUndo, !ui.isBusy else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Undo import?"
        alert.informativeText = "This will remove all calendar events added by the last image import. This cannot be undone again."
        alert.addButton(withTitle: "Undo Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        ui.isBusy = true
        ui.output = ""
        ui.status = "Undoing last image import..."
        ui.lastImageImportUndo = nil
        Task {
            do {
                let summary = try await calendarSyncEngine.revertImageImport(
                    record: record,
                    schedulingTimeZoneIdentifier: ui.schedulingTimeZoneIdentifier
                )
                ui.output = summary
                ui.status = "Import undone"
            } catch {
                ui.output = error.localizedDescription
                ui.status = "Undo failed"
            }
            ui.isBusy = false
        }
    }

    func runSync(previewOnly: Bool) {
        if ui.isBusy { return }
        let enabledSources = ui.sources.filter(\.enabled)
        guard !enabledSources.isEmpty else {
            ui.status = "Enable at least one source first"
            return
        }
        if !previewOnly {
            let enabledIDs = Set(enabledSources.map(\.id))
            let blockingReviews = ui.pendingAIReviews.filter { enabledIDs.contains($0.sourceItemID) }
            if !blockingReviews.isEmpty {
                let names = blockingReviews.map(\.sourceName).joined(separator: ", ")
                ui.status = "Approve AI layouts before syncing"
                ui.output = "AI review is still required for: \(names)\nRun Approve AI first, or Preview again after changing the parser settings."
                return
            }
        }

        if !previewOnly { ui.lastImageImportUndo = nil }
        ui.isBusy = true
        ui.output = ""
        ui.status = previewOnly ? "Previewing..." : "Syncing..."
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
                    previewOnly: previewOnly,
                    parserMode: ui.parserMode,
                    aiConfiguration: resolvedAIConfiguration,
                    aiApprovals: ui.aiApprovals,
                    schedulingTimeZoneIdentifier: ui.schedulingTimeZoneIdentifier
                )
                if previewOnly {
                    ui.output = result.outputText
                } else {
                    ui.output = "Sync at \(syncTimestampString(syncStartedAt))\n" + result.outputText
                }
                if previewOnly {
                    ui.pendingAIReviews = pendingReviews(from: result.reports)
                } else {
                    ui.pendingAIReviews = []
                }
                applySourceStatuses(from: result.reports)
                if previewOnly {
                    ui.status = "Preview complete"
                } else {
                    ui.status = "Sync complete\nSync at \(syncTimestampString(syncStartedAt))"
                }
            } catch {
                ui.output = error.localizedDescription
                if previewOnly {
                    ui.pendingAIReviews = []
                }
                clearLoadingStatuses()
                ui.status = error.localizedDescription
            }
            ui.isBusy = false
        }
    }

    func prepareCalendarsOnLaunch() {
        Task {
            let access = await calendarSyncEngine.calendarAccessState()
            applyCalendarAccessState(access, fallbackMessage: nil)
            guard access.hasUsableAccess, let values = await calendarSyncEngine.calendarNamesIfAuthorized() else {
                return
            }
            applyLoadedCalendars(values, statusMessage: values.isEmpty ? "No calendars found in Apple Calendar" : "Calendars loaded")
        }
    }

    func applyLoadedCalendars(_ values: [String], statusMessage: String) {
        ui.calendarAccessState = .granted
        ui.calendars = values.isEmpty ? ["Experiment"] : values
        if !ui.calendars.contains(ui.draftCalendar) {
            ui.draftCalendar = ui.calendars.first ?? "Experiment"
        }
        ui.output = ""
        ui.status = statusMessage
    }

    func applyCalendarAccessState(_ access: CalendarAccessState, fallbackMessage: String?) {
        ui.calendarAccessState = access
        switch access {
        case .unknown:
            ui.status = fallbackMessage ?? "Ready"
            if let fallbackMessage {
                ui.output = fallbackMessage
            } else {
                ui.output = ""
            }
        case .notDetermined:
            ui.status = "Calendar access needed"
            ui.output = fallbackMessage ?? ""
        case .granted:
            ui.status = fallbackMessage ?? ui.status
            if let fallbackMessage {
                ui.output = fallbackMessage
            } else if ui.output == access.helperText {
                ui.output = ""
            }
        case .denied, .restricted:
            ui.status = access == .denied ? "Calendar access is off" : "Calendar access is restricted"
            ui.output = fallbackMessage ?? ""
        }
    }

    func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
        ui.status = "Opened Calendar privacy settings"
    }

    func applySourceFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard isSupportedSourceFile(url) else {
            ui.status = "Unsupported file type"
            ui.output = "Drop an image or .xlsx workbook, or paste a Google Sheets link."
            return false
        }
        ui.draftSource = url.path
        ui.output = ""
        ui.status = "Selected source file"
        schedulePersist()
        return true
    }

    func applyDraftFields(from item: SourceItem) {
        if ui.draftEnabled != item.enabled {
            ui.draftEnabled = item.enabled
        }
        if ui.draftName != item.name {
            ui.draftName = item.name
        }
        if ui.draftSource != item.source {
            ui.draftSource = item.source
        }
        if ui.draftBookingID != item.bookingID {
            ui.draftBookingID = item.bookingID
        }
        if ui.draftCalendar != item.calendar {
            ui.draftCalendar = item.calendar
        }
    }

    func currentDraftState() -> DraftEditorState {
        DraftEditorState(
            selectedSourceID: ui.selectedSourceID,
            enabled: ui.draftEnabled,
            name: ui.draftName,
            source: ui.draftSource,
            bookingID: ui.draftBookingID,
            calendar: ui.draftCalendar
        )
    }

    func isSupportedSourceFile(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "xlsx" {
            return true
        }
        return imageMimeType(for: url) != nil
    }
}
