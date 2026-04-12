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

    // MARK: - AIServiceConfiguration

    func testAIServiceConfigurationRequestStyle() {
        let makeConfig = { (provider: AIProvider) -> AIServiceConfiguration in
            AIServiceConfiguration(
                provider: provider,
                endpointURL: URL(string: provider.defaultEndpointURL)!,
                apiKey: "test",
                model: provider.defaultModel
            )
        }
        XCTAssertEqual(makeConfig(.openAI).requestStyle, .responses)
        XCTAssertEqual(makeConfig(.anthropic).requestStyle, .anthropicMessages)
        XCTAssertEqual(makeConfig(.gemini).requestStyle, .geminiGenerateContent)
        XCTAssertEqual(makeConfig(.deepSeek).requestStyle, .chatCompletions)
        XCTAssertEqual(makeConfig(.kimi).requestStyle, .chatCompletions)
        XCTAssertEqual(makeConfig(.openRouter).requestStyle, .chatCompletions)
    }

    func testAIServiceConfigurationResolvedModel() {
        let config = AIServiceConfiguration(
            provider: .anthropic,
            endpointURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKey: "test",
            model: ""
        )
        XCTAssertEqual(config.resolvedModel(forImageParsing: false), "claude-sonnet-4-6")
        XCTAssertEqual(config.resolvedModel(forImageParsing: true), "claude-sonnet-4-6")
    }

    func testAIServiceConfigurationManualModelOverride() {
        let config = AIServiceConfiguration(
            provider: .anthropic,
            endpointURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKey: "test",
            model: "claude-opus-4-6"
        )
        XCTAssertEqual(config.resolvedModel(forImageParsing: false), "claude-opus-4-6")
        XCTAssertEqual(config.resolvedModel(forImageParsing: true), "claude-opus-4-6")
    }

    func testCustomProviderRequestStyleInference() {
        let chatConfig = AIServiceConfiguration(
            provider: .custom,
            endpointURL: URL(string: "https://my-proxy.com/v1/chat/completions")!,
            apiKey: "test",
            model: "custom-model"
        )
        XCTAssertEqual(chatConfig.requestStyle, .chatCompletions)

        let anthropicConfig = AIServiceConfiguration(
            provider: .custom,
            endpointURL: URL(string: "https://proxy.anthropic.com/v1/messages")!,
            apiKey: "test",
            model: "custom-model"
        )
        XCTAssertEqual(anthropicConfig.requestStyle, .anthropicMessages)

        let geminiConfig = AIServiceConfiguration(
            provider: .custom,
            endpointURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!,
            apiKey: "test",
            model: "custom-model"
        )
        XCTAssertEqual(geminiConfig.requestStyle, .geminiGenerateContent)
    }

    // MARK: - AIParserSettings decode inference

    func testAIParserSettingsInfersProviderFromEndpoint() throws {
        let json = """
        {"endpointURL": "https://api.anthropic.com/v1/messages", "model": "claude-sonnet-4-6"}
        """
        let decoded = try JSONDecoder().decode(AIParserSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.provider, .anthropic)
        XCTAssertEqual(decoded.endpointURL, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(decoded.model, "claude-sonnet-4-6")
    }

    func testAIParserSettingsDefaultsEmptyEndpoint() throws {
        let json = """
        {"provider": "gemini", "endpointURL": "", "model": ""}
        """
        let decoded = try JSONDecoder().decode(AIParserSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.provider, .gemini)
        XCTAssertEqual(decoded.endpointURL, defaultGeminiEndpointURL, "Empty endpoint should fall back to provider default")
    }

    func testAIParserSettingsInitDefault() {
        let settings = AIParserSettings()
        XCTAssertEqual(settings.provider, defaultAIProvider)
        XCTAssertEqual(settings.endpointURL, defaultAIProvider.defaultEndpointURL)
        XCTAssertEqual(settings.model, "")
    }

    // MARK: - AppSettings roundtrip completeness

    func testRoundtripPreservesAllFields() throws {
        let original = AppSettings(
            sources: [SourceItem(name: "t", source: "/f.xlsx", bookingID: "B", calendar: "C")],
            workdayHours: WorkdayHours(start: "08:00", end: "20:00"),
            schedulingTimeZoneIdentifier: "Europe/London",
            autoSyncEnabled: true,
            autoSyncMinutes: 42,
            upcomingOnly: false,
            confirmBeforeSync: true,
            confirmBeforeDeletion: false,
            menuBarModeEnabled: true,
            parserMode: .aiOnly,
            aiParser: AIParserSettings(provider: .gemini, endpointURL: "https://custom.endpoint/v1", model: "custom-model"),
            aiApprovals: [AIApprovalRecord(sourceKey: "sk", workbookFingerprint: "fp", approvedAtISO: "2025-01-01T00:00:00Z")],
            lastDraft: DraftEditorState(selectedSourceID: nil, enabled: true, name: "d", source: "s", bookingID: "b", calendar: "c")
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.aiParser.provider, .gemini)
        XCTAssertEqual(decoded.aiParser.endpointURL, "https://custom.endpoint/v1")
        XCTAssertEqual(decoded.aiParser.model, "custom-model")
        XCTAssertEqual(decoded.aiApprovals.count, 1)
        XCTAssertEqual(decoded.aiApprovals.first?.sourceKey, "sk")
        XCTAssertNotNil(decoded.lastDraft)
        XCTAssertEqual(decoded.lastDraft?.name, "d")
        XCTAssertEqual(decoded.autoSyncMinutes, 42)
        XCTAssertEqual(decoded.menuBarModeEnabled, true)
    }

    // MARK: - Provider coverage completeness

    func testAllProvidersHaveImageSupportDefined() {
        for provider in AIProvider.allCases {
            _ = provider.supportsImageParsing
            _ = provider.requiresImageReviewByDefault
        }
    }

    func testKimiImageModelSwitch() {
        XCTAssertNotNil(AIProvider.kimi.defaultImageModel)
        XCTAssertNotEqual(AIProvider.kimi.defaultImageModel, AIProvider.kimi.defaultModel)
    }

    func testInferAIProviderWithSpacesAndCase() {
        XCTAssertEqual(inferAIProvider(fromEndpoint: "  HTTPS://API.ANTHROPIC.COM/v1/messages  "), .anthropic)
        XCTAssertEqual(inferAIProvider(fromEndpoint: "  https://api.deepseek.com/chat/completions  "), .deepSeek)
    }
}
