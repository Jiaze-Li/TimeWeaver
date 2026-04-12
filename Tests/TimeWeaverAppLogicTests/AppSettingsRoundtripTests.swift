import XCTest
@testable import TimeWeaverAppLogic

final class AppSettingsRoundtripTests: XCTestCase {
    func testAppSettingsEncodesAndDecodes() throws {
        let original = AppSettings(
            sources: [
                SourceItem(name: "test", source: "/path/to/file.xlsx", bookingID: "ABC", calendar: "Work")
            ],
            workdayHours: WorkdayHours(start: "09:00", end: "17:00"),
            schedulingTimeZoneIdentifier: "America/New_York",
            autoSyncEnabled: true,
            autoSyncMinutes: 30,
            upcomingOnly: false,
            confirmBeforeSync: false,
            confirmBeforeDeletion: true,
            menuBarModeEnabled: true,
            parserMode: .aiOnly,
            aiParser: AIParserSettings(provider: .anthropic, endpointURL: "https://api.anthropic.com/v1/messages", model: "claude-sonnet-4-6"),
            aiApprovals: [],
            lastDraft: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.sources.count, 1)
        XCTAssertEqual(decoded.sources.first?.name, "test")
        XCTAssertEqual(decoded.workdayHours.start, "09:00")
        XCTAssertEqual(decoded.schedulingTimeZoneIdentifier, "America/New_York")
        XCTAssertEqual(decoded.autoSyncEnabled, true)
        XCTAssertEqual(decoded.autoSyncMinutes, 30)
        XCTAssertEqual(decoded.upcomingOnly, false)
        XCTAssertEqual(decoded.confirmBeforeSync, false)
        XCTAssertEqual(decoded.confirmBeforeDeletion, true)
        XCTAssertEqual(decoded.menuBarModeEnabled, true)
        XCTAssertEqual(decoded.parserMode, .aiOnly)
        XCTAssertEqual(decoded.aiParser.provider, .anthropic)
        XCTAssertEqual(decoded.aiParser.model, "claude-sonnet-4-6")
    }

    func testAIProviderInference() {
        XCTAssertEqual(inferAIProvider(fromEndpoint: "https://api.anthropic.com/v1/messages"), .anthropic)
        XCTAssertEqual(inferAIProvider(fromEndpoint: "https://generativelanguage.googleapis.com/v1beta/models"), .gemini)
        XCTAssertEqual(inferAIProvider(fromEndpoint: "https://api.openai.com/v1/responses"), .openAI)
        XCTAssertEqual(inferAIProvider(fromEndpoint: "https://api.deepseek.com/chat/completions"), .deepSeek)
        XCTAssertEqual(inferAIProvider(fromEndpoint: "https://api.moonshot.cn/v1/chat/completions"), .kimi)
        XCTAssertEqual(inferAIProvider(fromEndpoint: "https://openrouter.ai/api/v1/chat/completions"), .openRouter)
        XCTAssertEqual(inferAIProvider(fromEndpoint: "https://custom.api.example.com/v1/chat"), .custom)
    }

    func testAIProviderDefaultModels() {
        XCTAssertEqual(AIProvider.anthropic.defaultModel, "claude-sonnet-4-6")
        XCTAssertEqual(AIProvider.gemini.defaultModel, "gemini-2.5-flash")
        XCTAssertEqual(AIProvider.openAI.defaultModel, "gpt-5.4")
        XCTAssertEqual(AIProvider.deepSeek.defaultModel, "deepseek-chat")
    }

    func testAIProviderImageSupport() {
        XCTAssertTrue(AIProvider.anthropic.supportsImageParsing)
        XCTAssertTrue(AIProvider.gemini.supportsImageParsing)
        XCTAssertTrue(AIProvider.openAI.supportsImageParsing)
        XCTAssertFalse(AIProvider.deepSeek.supportsImageParsing)
    }

    func testSlotRuleTypealiasWorks() {
        let rule = SlotRule(sheetLabel: "test", start: "09:00", end: "17:00", endsNextDay: false)
        XCTAssertEqual(rule.sheetLabel, "test")
        XCTAssertFalse(rule.endsNextDay)
    }

    func testWorkdayHoursEquality() {
        let a = WorkdayHours(start: "09:00", end: "17:00")
        let b = WorkdayHours(start: "09:00", end: "17:00")
        let c = WorkdayHours(start: "10:00", end: "18:00")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
