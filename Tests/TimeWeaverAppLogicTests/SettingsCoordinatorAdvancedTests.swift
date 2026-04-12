import XCTest
@testable import TimeWeaverAppLogic

@MainActor
final class SettingsCoordinatorAdvancedTests: XCTestCase {

    private static func makeSettings(
        bookingID: String = "test",
        autoSync: Bool = false
    ) -> AppSettings {
        AppSettings(
            sources: [SourceItem(name: "s", source: "sheet", bookingID: bookingID, calendar: defaultCalendarName)],
            workdayHours: WorkdayHours(start: "09:00", end: "17:00"),
            schedulingTimeZoneIdentifier: defaultSchedulingTimeZoneIdentifier,
            autoSyncEnabled: autoSync,
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

    func testPersistCalledOnSettingsChange() {
        var persistCount = 0

        let coordinator = SettingsCoordinator(
            loadSettings: { Self.makeSettings() },
            loadAIAPIKey: { "" },
            saveAIAPIKey: { _ in },
            saveSettings: { _ in persistCount += 1 },
            persistExecutor: { work in work() }
        )

        let s1 = Self.makeSettings(bookingID: "a")
        let s2 = Self.makeSettings(bookingID: "b")

        let d1 = try! JSONEncoder().encode(s1)
        let d2 = try! JSONEncoder().encode(s2)

        coordinator.persistIfNeeded(settings: s1, encodedData: d1, aiAPIKey: "k")
        coordinator.persistIfNeeded(settings: s2, encodedData: d2, aiAPIKey: "k")

        XCTAssertEqual(persistCount, 2, "Two different settings payloads should persist twice")
    }

    func testPersistSkippedWhenIdentical() {
        var persistCount = 0

        let coordinator = SettingsCoordinator(
            loadSettings: { Self.makeSettings() },
            loadAIAPIKey: { "" },
            saveAIAPIKey: { _ in },
            saveSettings: { _ in persistCount += 1 },
            persistExecutor: { work in work() }
        )

        let s = Self.makeSettings()
        let d = try! JSONEncoder().encode(s)

        coordinator.persistIfNeeded(settings: s, encodedData: d, aiAPIKey: "k")
        coordinator.persistIfNeeded(settings: s, encodedData: d, aiAPIKey: "k")
        coordinator.persistIfNeeded(settings: s, encodedData: d, aiAPIKey: "k")

        XCTAssertEqual(persistCount, 1, "Identical payloads should persist only once")
    }

    func testPersistTriggeredByAPIKeyChangeOnly() {
        var savedKeys: [String] = []

        let coordinator = SettingsCoordinator(
            loadSettings: { Self.makeSettings() },
            loadAIAPIKey: { "" },
            saveAIAPIKey: { savedKeys.append($0) },
            saveSettings: { _ in },
            persistExecutor: { work in work() }
        )

        let s = Self.makeSettings()
        let d = try! JSONEncoder().encode(s)

        coordinator.persistIfNeeded(settings: s, encodedData: d, aiAPIKey: "key1")
        coordinator.persistIfNeeded(settings: s, encodedData: d, aiAPIKey: "key2")
        coordinator.persistIfNeeded(settings: s, encodedData: d, aiAPIKey: "key3")

        XCTAssertEqual(savedKeys, ["key1", "key2", "key3"])
    }

    func testLoadSettingsReturnsInjectedValue() {
        let expected = Self.makeSettings(bookingID: "injected")

        let coordinator = SettingsCoordinator(
            loadSettings: { expected },
            loadAIAPIKey: { "secret" },
            saveAIAPIKey: { _ in },
            saveSettings: { _ in },
            persistExecutor: { work in work() }
        )

        let loaded = coordinator.loadSettings()
        XCTAssertEqual(loaded.sources.first?.bookingID, "injected")

        let key = coordinator.loadAIAPIKey()
        XCTAssertEqual(key, "secret")
    }

    func testAIProviderEndpointAutoFill() {
        for provider in AIProvider.allCases where provider != .custom {
            XCTAssertFalse(provider.defaultEndpointURL.isEmpty, "\(provider.title) should have a default endpoint")
            XCTAssertFalse(provider.defaultModel.isEmpty, "\(provider.title) should have a default model")
        }
        XCTAssertTrue(AIProvider.custom.defaultEndpointURL.isEmpty)
        XCTAssertTrue(AIProvider.custom.defaultModel.isEmpty)
    }

    func testParserModeAllCases() {
        XCTAssertEqual(ParserMode.allCases.count, 3)
        XCTAssertEqual(ParserMode.rulesOnly.rawValue, "rules_only")
        XCTAssertEqual(ParserMode.auto.rawValue, "auto")
        XCTAssertEqual(ParserMode.aiOnly.rawValue, "ai_only")
    }
}
