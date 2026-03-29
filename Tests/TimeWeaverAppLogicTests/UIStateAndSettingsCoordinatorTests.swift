import XCTest
@testable import TimeWeaverAppLogic

final class UIStateAndSettingsCoordinatorTests: XCTestCase {
    func testUIStateInitialSeedsExpectedDefaults() {
        let source = SourceItem(name: "ppms", source: "sheet", bookingID: "LJZ", calendar: "Experiment")
        let state = UIState.initial(
            sources: [source],
            sourceStatuses: [source.id: .idle],
            workdayStart: "09:00",
            workdayEnd: "18:00",
            selectedSourceID: source.id,
            draftEnabled: true,
            draftName: "draft",
            draftSource: "sheet",
            draftBookingID: "LJZ",
            draftCalendar: "Experiment",
            autoSyncEnabled: true,
            autoSyncMinutes: "15",
            upcomingOnly: true,
            confirmBeforeSync: true,
            confirmBeforeDeletion: true,
            menuBarModeEnabled: false,
            parserMode: .auto,
            aiProvider: .openAI,
            aiEndpointURL: "https://api.openai.com/v1/responses",
            aiModel: "",
            aiAPIKey: "k",
            aiApprovals: [],
            schedulingTimeZoneIdentifier: "Asia/Singapore"
        )

        XCTAssertEqual(state.sources.count, 1)
        XCTAssertEqual(state.selectedSourceID, source.id)
        XCTAssertEqual(state.calendars, ["Experiment"])
        XCTAssertEqual(state.calendarAccessState, .unknown)
        XCTAssertEqual(state.status, "Ready")
        XCTAssertFalse(state.isBusy)
        XCTAssertFalse(state.isCalendarLoading)
        XCTAssertEqual(state.pendingAIReviews.count, 0)
        XCTAssertNil(state.pendingSyncConfirmation)
    }

    func testSettingsCoordinatorSkipsDuplicatePersistPayload() {
        var savedSettings = 0
        var savedKeys: [String] = []

        let coordinator = SettingsCoordinator(
            loadSettings: { Self.makeSettings() },
            loadAIAPIKey: { "" },
            saveAIAPIKey: { savedKeys.append($0) },
            saveSettings: { _ in savedSettings += 1 },
            persistExecutor: { work in work() }
        )

        let settings = Self.makeSettings()
        let encoded = try! JSONEncoder().encode(settings)

        coordinator.persistIfNeeded(settings: settings, encodedData: encoded, aiAPIKey: "k1")
        coordinator.persistIfNeeded(settings: settings, encodedData: encoded, aiAPIKey: "k1")

        XCTAssertEqual(savedSettings, 1)
        XCTAssertEqual(savedKeys, ["k1"])
    }

    func testSettingsCoordinatorPersistsWhenKeyChanges() {
        var savedSettings = 0
        var savedKeys: [String] = []

        let coordinator = SettingsCoordinator(
            loadSettings: { Self.makeSettings() },
            loadAIAPIKey: { "" },
            saveAIAPIKey: { savedKeys.append($0) },
            saveSettings: { _ in savedSettings += 1 },
            persistExecutor: { work in work() }
        )

        let settings = Self.makeSettings()
        let encoded = try! JSONEncoder().encode(settings)

        coordinator.persistIfNeeded(settings: settings, encodedData: encoded, aiAPIKey: "k1")
        coordinator.persistIfNeeded(settings: settings, encodedData: encoded, aiAPIKey: "k2")

        XCTAssertEqual(savedSettings, 2)
        XCTAssertEqual(savedKeys, ["k1", "k2"])
    }

    private static func makeSettings() -> AppSettings {
        AppSettings(
            sources: [SourceItem(name: "ppms", source: "sheet", bookingID: "LJZ", calendar: "Experiment")],
            workdayHours: WorkdayHours(start: "10:00", end: "20:00"),
            schedulingTimeZoneIdentifier: "Asia/Singapore",
            autoSyncEnabled: false,
            autoSyncMinutes: 15,
            upcomingOnly: true,
            confirmBeforeSync: true,
            confirmBeforeDeletion: true,
            menuBarModeEnabled: false,
            parserMode: .auto,
            aiParser: AIParserSettings(),
            aiApprovals: [],
            lastDraft: nil
        )
    }
}
