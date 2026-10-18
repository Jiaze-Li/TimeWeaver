import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var ui: UIState

    let calendarSyncEngine: CalendarSyncEngine
    let settingsCoordinator = SettingsCoordinator()
    let launchAutomation = LaunchAutomation.load()
    var timer: Timer?
    var persistTask: Task<Void, Never>?
    @Published var ignoredReviews: [IgnoredAutoReview] = []
    @Published var showIgnoredReviews = false
    var isApplyingBackgroundReview = false
    var isBackgroundCheckLaunch: Bool { BackgroundCheckLaunch.isRequested() }
    @Published var isCheckingAutomatically = false
    var autoReviewWindowController: NSWindowController?

    init(calendarSyncEngine: CalendarSyncEngine = CalendarSyncEngine()) {
        self.calendarSyncEngine = calendarSyncEngine
        let settings = settingsCoordinator.loadSettings()
        var initialSources = settings.sources

        var initialSelectedSourceID: UUID?
        var initialDraftEnabled = true
        var initialDraftName = ""
        var initialDraftSource = ""
        var initialDraftBookingID = ""
        var initialDraftCalendar = defaultCalendarName

        if let lastDraft = settings.lastDraft {
            initialSelectedSourceID = lastDraft.selectedSourceID
            initialDraftEnabled = lastDraft.enabled
            initialDraftName = lastDraft.name
            initialDraftSource = lastDraft.source
            initialDraftBookingID = lastDraft.bookingID
            initialDraftCalendar = lastDraft.calendar
        } else if let first = settings.sources.first {
            initialSelectedSourceID = first.id
            initialDraftEnabled = first.enabled
            initialDraftName = first.name
            initialDraftSource = first.source
            initialDraftBookingID = first.bookingID
            initialDraftCalendar = first.calendar
        } else {
            let first = defaultSources()[0]
            initialSources = [first]
            initialSelectedSourceID = first.id
            initialDraftEnabled = first.enabled
            initialDraftName = first.name
            initialDraftSource = first.source
            initialDraftBookingID = first.bookingID
            initialDraftCalendar = first.calendar
        }

        let sourceStatuses = Dictionary(uniqueKeysWithValues: initialSources.map { ($0.id, SourceRuntimeStatus.idle) })
        let storedModel = settings.aiParser.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialAIModel: String
        if settings.aiParser.provider != .custom && storedModel == settings.aiParser.provider.defaultModel {
            initialAIModel = ""
        } else {
            initialAIModel = storedModel
        }

        ui = UIState.initial(
            sources: initialSources,
            sourceStatuses: sourceStatuses,
            workdayStart: settings.workdayHours.start,
            workdayEnd: settings.workdayHours.end,
            selectedSourceID: initialSelectedSourceID,
            draftEnabled: initialDraftEnabled,
            draftName: initialDraftName,
            draftSource: initialDraftSource,
            draftBookingID: initialDraftBookingID,
            draftCalendar: initialDraftCalendar,
            autoSyncEnabled: settings.autoSyncEnabled,
            autoSyncMinutes: String(settings.autoSyncMinutes),
            upcomingOnly: settings.upcomingOnly,
            confirmBeforeSync: settings.confirmBeforeSync,
            confirmBeforeDeletion: settings.confirmBeforeDeletion,
            menuBarModeEnabled: settings.menuBarModeEnabled,
            parserMode: settings.parserMode,
            aiProvider: settings.aiParser.provider,
            aiEndpointURL: settings.aiParser.endpointURL,
            aiModel: initialAIModel,
            aiAPIKey: settingsCoordinator.loadAIAPIKey(),
            aiApprovals: settings.aiApprovals,
            schedulingTimeZoneIdentifier: settings.schedulingTimeZoneIdentifier
        )

        ignoredReviews = SettingsStore.loadIgnoredReviews()
        reconcileSourceStatuses()
        prepareCalendarsOnLaunch()
        rescheduleTimer()
        if !isBackgroundCheckLaunch {
            runLaunchAutomationIfNeeded()
        }
    }

    deinit {
        timer?.invalidate()
        persistTask?.cancel()
        let controller = autoReviewWindowController
        if let controller {
            Task { @MainActor in
                controller.close()
            }
        }
    }



    /// Shared entry point for the "start a busy async task" triplet (isBusy/output/status),
    /// so every long-running action begins from the same, single guarded state transition.
    func beginBusyTask(status: String) {
        ui.isBusy = true
        ui.output = ""
        ui.status = status
    }
}
