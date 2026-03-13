import SwiftUI
import AppKit
import CryptoKit
import Foundation
import EventKit
import Security
import UniformTypeIdentifiers

private let appDisplayName = "TimeWeaver"
private let appTagline = "Turn sheets, timetables, and images into Apple Calendar events"

private let appSupportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PPMSCalendarSync", isDirectory: true)
private let settingsURL = appSupportDirectory.appendingPathComponent("settings.json")
private let stateURL = appSupportDirectory.appendingPathComponent("sync-state.json")

struct SourceItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String
    var source: String
    var bookingID: String
    var calendar: String
}

struct SlotRule: Codable, Equatable {
    var sheetLabel: String
    var start: String
    var end: String
    var endsNextDay: Bool
}

struct WorkdayHours: Codable, Equatable {
    var start: String
    var end: String
}

enum ParserMode: String, Codable, CaseIterable, Identifiable {
    case rulesOnly = "rules_only"
    case auto = "auto"
    case aiOnly = "ai_only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rulesOnly:
            return "Rules"
        case .auto:
            return "Auto"
        case .aiOnly:
            return "AI"
        }
    }

    var summary: String {
        switch self {
        case .rulesOnly:
            return "Use the built-in sheet rules only."
        case .auto:
            return "Try built-in rules first, then ask AI when the layout is unfamiliar."
        case .aiOnly:
            return "Always ask AI to normalize the workbook."
        }
    }

    var inlineSummary: String {
        switch self {
        case .rulesOnly:
            return "Built-in only"
        case .auto:
            return "Try built-in first"
        case .aiOnly:
            return "AI only"
        }
    }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case kimi = "kimi"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case openRouter = "openrouter"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .deepSeek:
            return "DeepSeek"
        case .kimi:
            return "Kimi"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        case .openRouter:
            return "OpenRouter"
        case .custom:
            return "Custom"
        }
    }

    var pickerTitle: String {
        switch self {
        case .gemini:
            return "\(title) (images, recommended)"
        case .openAI, .anthropic, .openRouter:
            return "\(title) \(supportsImageParsing ? "(images, review)" : "(text only)")"
        case .kimi:
            return "\(title) (images, experimental)"
        case .deepSeek:
            return "\(title) (text only)"
        case .custom:
            return "\(title) \(supportsImageParsing ? "(images, manual)" : "(text only)")"
        }
    }

    var summary: String {
        switch self {
        case .openAI:
            return "Built-in setup for OpenAI Responses API."
        case .deepSeek:
            return "Built-in setup for DeepSeek chat completions."
        case .kimi:
            return "Built-in setup for Moonshot Kimi chat completions. Text uses the standard model and image sources automatically switch to the built-in vision model."
        case .anthropic:
            return "Built-in setup for Anthropic Messages API."
        case .gemini:
            return "Built-in setup for Gemini generateContent."
        case .openRouter:
            return "Built-in setup for OpenRouter chat completions."
        case .custom:
            return "Manual endpoint and model for custom, proxy, or self-hosted deployments."
        }
    }

    var defaultEndpointURL: String {
        switch self {
        case .openAI:
            return defaultOpenAIEndpointURL
        case .deepSeek:
            return defaultDeepSeekEndpointURL
        case .kimi:
            return defaultKimiEndpointURL
        case .anthropic:
            return defaultAnthropicEndpointURL
        case .gemini:
            return defaultGeminiEndpointURL
        case .openRouter:
            return defaultOpenRouterEndpointURL
        case .custom:
            return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            return defaultOpenAIModel
        case .deepSeek:
            return defaultDeepSeekModel
        case .kimi:
            return defaultKimiModel
        case .anthropic:
            return defaultAnthropicModel
        case .gemini:
            return defaultGeminiModel
        case .openRouter:
            return defaultOpenRouterModel
        case .custom:
            return ""
        }
    }

    var automaticSheetModel: String {
        defaultModel
    }

    var defaultImageModel: String? {
        switch self {
        case .kimi:
            return defaultKimiImageModel
        case .openAI, .anthropic, .gemini, .openRouter, .deepSeek, .custom:
            return nil
        }
    }

    var automaticImageModel: String {
        defaultImageModel ?? automaticSheetModel
    }

    var automaticModelSummary: String {
        if automaticImageModel == automaticSheetModel {
            return automaticSheetModel
        }
        return "sheet: \(automaticSheetModel), image: \(automaticImageModel)"
    }

    var supportsImageParsing: Bool {
        switch self {
        case .deepSeek:
            return false
        case .openAI, .kimi, .anthropic, .gemini, .openRouter, .custom:
            return true
        }
    }

    var requiresImageReviewByDefault: Bool {
        switch self {
        case .openAI, .kimi, .anthropic, .gemini, .openRouter, .custom, .deepSeek:
            return true
        }
    }
}

struct AIParserSettings: Codable, Equatable {
    var provider: AIProvider
    var endpointURL: String
    var model: String

    enum CodingKeys: String, CodingKey {
        case provider
        case endpointURL
        case model
    }

    init(provider: AIProvider = defaultAIProvider, endpointURL: String? = nil, model: String? = nil) {
        self.provider = provider
        self.endpointURL = endpointURL ?? provider.defaultEndpointURL
        self.model = model ?? ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEndpoint = try container.decodeIfPresent(String.self, forKey: .endpointURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let decodedModel = try container.decodeIfPresent(String.self, forKey: .model)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inferredProvider = try container.decodeIfPresent(AIProvider.self, forKey: .provider)
            ?? inferAIProvider(fromEndpoint: decodedEndpoint)

        self.provider = inferredProvider
        self.endpointURL = decodedEndpoint.isEmpty ? inferredProvider.defaultEndpointURL : decodedEndpoint
        self.model = decodedModel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(endpointURL, forKey: .endpointURL)
        try container.encode(model, forKey: .model)
    }
}

struct AIApprovalRecord: Codable, Equatable, Identifiable {
    var sourceKey: String
    var workbookFingerprint: String
    var approvedAtISO: String

    var id: String { "\(sourceKey)|\(workbookFingerprint)" }
}

struct PendingAIReview: Identifiable, Equatable {
    var sourceItemID: UUID
    var sourceName: String
    var workbookFingerprint: String
    var parserLabel: String
    var averageConfidence: Double?
    var minimumConfidence: Double?

    var id: UUID { sourceItemID }
}

struct DraftEditorState: Codable, Equatable {
    var selectedSourceID: UUID?
    var enabled: Bool
    var name: String
    var source: String
    var bookingID: String
    var calendar: String
}

struct AppSettings: Codable {
    var sources: [SourceItem]
    var workdayHours: WorkdayHours
    var autoSyncEnabled: Bool
    var autoSyncMinutes: Int
    var upcomingOnly: Bool
    var confirmBeforeSync: Bool
    var confirmBeforeDeletion: Bool
    var menuBarModeEnabled: Bool
    var parserMode: ParserMode
    var aiParser: AIParserSettings
    var aiApprovals: [AIApprovalRecord]
    var lastDraft: DraftEditorState?

    enum CodingKeys: String, CodingKey {
        case sources
        case workdayHours
        case slotRules
        case autoSyncEnabled
        case autoSyncMinutes
        case upcomingOnly
        case confirmBeforeSync
        case confirmBeforeDeletion
        case menuBarModeEnabled
        case parserMode
        case aiParser
        case aiApprovals
        case lastDraft
    }

    init(
        sources: [SourceItem],
        workdayHours: WorkdayHours,
        autoSyncEnabled: Bool,
        autoSyncMinutes: Int,
        upcomingOnly: Bool,
        confirmBeforeSync: Bool,
        confirmBeforeDeletion: Bool,
        menuBarModeEnabled: Bool,
        parserMode: ParserMode,
        aiParser: AIParserSettings,
        aiApprovals: [AIApprovalRecord],
        lastDraft: DraftEditorState?
    ) {
        self.sources = sources
        self.workdayHours = workdayHours
        self.autoSyncEnabled = autoSyncEnabled
        self.autoSyncMinutes = autoSyncMinutes
        self.upcomingOnly = upcomingOnly
        self.confirmBeforeSync = confirmBeforeSync
        self.confirmBeforeDeletion = confirmBeforeDeletion
        self.menuBarModeEnabled = menuBarModeEnabled
        self.parserMode = parserMode
        self.aiParser = aiParser
        self.aiApprovals = aiApprovals
        self.lastDraft = lastDraft
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decodeIfPresent([SourceItem].self, forKey: .sources) ?? defaultSources()
        self.workdayHours = try container.decodeIfPresent(WorkdayHours.self, forKey: .workdayHours)
            ?? defaultWorkdayHours()
        self.autoSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled) ?? false
        self.autoSyncMinutes = try container.decodeIfPresent(Int.self, forKey: .autoSyncMinutes) ?? 15
        self.upcomingOnly = try container.decodeIfPresent(Bool.self, forKey: .upcomingOnly) ?? true
        self.confirmBeforeSync = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeSync) ?? true
        self.confirmBeforeDeletion = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeDeletion) ?? true
        self.menuBarModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .menuBarModeEnabled) ?? false
        self.parserMode = try container.decodeIfPresent(ParserMode.self, forKey: .parserMode) ?? .auto
        self.aiParser = try container.decodeIfPresent(AIParserSettings.self, forKey: .aiParser) ?? AIParserSettings()
        self.aiApprovals = try container.decodeIfPresent([AIApprovalRecord].self, forKey: .aiApprovals) ?? []
        self.lastDraft = try container.decodeIfPresent(DraftEditorState.self, forKey: .lastDraft)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sources, forKey: .sources)
        try container.encode(workdayHours, forKey: .workdayHours)
        try container.encode(autoSyncEnabled, forKey: .autoSyncEnabled)
        try container.encode(autoSyncMinutes, forKey: .autoSyncMinutes)
        try container.encode(upcomingOnly, forKey: .upcomingOnly)
        try container.encode(confirmBeforeSync, forKey: .confirmBeforeSync)
        try container.encode(confirmBeforeDeletion, forKey: .confirmBeforeDeletion)
        try container.encode(menuBarModeEnabled, forKey: .menuBarModeEnabled)
        try container.encode(parserMode, forKey: .parserMode)
        try container.encode(aiParser, forKey: .aiParser)
        try container.encode(aiApprovals, forKey: .aiApprovals)
        try container.encodeIfPresent(lastDraft, forKey: .lastDraft)
    }
}

struct StoredEvent: Codable {
    var eventIdentifier: String
    var sourceID: String
    var calendar: String
    var title: String
    var startISO: String
    var endISO: String
}

struct SyncState: Codable {
    var events: [String: StoredEvent]
}

struct WorkbookSheet {
    var name: String
    var relationshipID: String
    var state: String
}

struct SlotOccurrence {
    var start: Date
    var end: Date
    var sheetName: String
    var cellReference: String
    var slotLabel: String
    var isAllDay: Bool
}

struct ReservationEvent: Identifiable {
    var id: String { syncKey }
    var syncKey: String
    var sourceID: String
    var sourceName: String
    var sourceLink: String
    var bookingID: String
    var calendarName: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var sheetNames: [String]
    var cellReferences: [String]
}

struct EventAction {
    var status: String
    var title: String
    var start: Date
    var end: Date
}

struct DeleteCandidate {
    var syncKey: String
    var eventIdentifier: String
    var title: String
    var startISO: String
    var endISO: String
}

struct PendingSyncConfirmation: Identifiable {
    var id = UUID()
    var message: String
}

struct ImageImportPlan {
    var source: SourceItem
    var matchedCount: Int
    var createCount: Int
    var updateCount: Int
    var deleteCount: Int
    var reviewRequired: Bool
    var workbookFingerprint: String?
    var previewOutput: String
    var sampleIntervals: [String]
}

struct SourceSyncReport: Identifiable {
    var id = UUID()
    var sourceItemID: UUID
    var sourceName: String
    var bookingID: String
    var calendarName: String
    var parserLabel: String
    var parserNotes: [String]
    var reviewRequired: Bool
    var workbookFingerprint: String?
    var averageConfidence: Double?
    var minimumConfidence: Double?
    var totalMatchedCount: Int
    var syncedMatchedCount: Int
    var filteredPastCount: Int
    var actions: [EventAction]
    var deleteCandidates: [DeleteCandidate]
    var errorMessage: String?
}

struct SyncRunResult {
    var reports: [SourceSyncReport]
    var outputText: String
}

struct ExtractionResult {
    var allEvents: [ReservationEvent]
    var filteredEvents: [ReservationEvent]
    var filteredPastCount: Int
    var parserLabel: String
    var parserNotes: [String]
    var reviewRequired: Bool
    var workbookFingerprint: String?
    var averageConfidence: Double?
    var minimumConfidence: Double?
}

private struct LaunchAutomation: Codable {
    private static let controlFileURL = URL(fileURLWithPath: "/tmp/ppms_launch_automation.json")

    enum Action: String, Codable {
        case preview
        case sync
    }

    var action: Action
    var outputPath: String
    var terminateAfterCompletion: Bool
    var sources: [SourceItem]?
    var workdayHours: WorkdayHours?
    var upcomingOnly: Bool?
    var parserMode: ParserMode?
    var aiProvider: AIProvider?
    var aiEndpointURL: String?
    var aiModel: String?
    var aiAPIKey: String?

    static func fromEnvironment() -> LaunchAutomation? {
        let environment = ProcessInfo.processInfo.environment
        guard let actionRaw = environment["PPMS_AUTOTEST_ACTION"],
              let action = Action(rawValue: actionRaw),
              let outputPath = environment["PPMS_AUTOTEST_OUTPUT"],
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let terminateAfterCompletion = environment["PPMS_AUTOTEST_EXIT"] == "1"
        return LaunchAutomation(
            action: action,
            outputPath: outputPath,
            terminateAfterCompletion: terminateAfterCompletion,
            sources: nil,
            workdayHours: nil,
            upcomingOnly: nil,
            parserMode: nil,
            aiProvider: nil,
            aiEndpointURL: nil,
            aiModel: nil,
            aiAPIKey: nil
        )
    }

    static func load() -> LaunchAutomation? {
        if let fromEnvironment = fromEnvironment() {
            return fromEnvironment
        }
        guard let data = try? Data(contentsOf: controlFileURL),
              let automation = try? JSONDecoder().decode(LaunchAutomation.self, from: data) else {
            return nil
        }
        try? FileManager.default.removeItem(at: controlFileURL)
        return automation
    }

    static func save(_ automation: LaunchAutomation) throws {
        let data = try JSONEncoder().encode(automation)
        try data.write(to: controlFileURL)
    }
}

enum SourceRuntimeStatus: Equatable {
    case idle
    case loading
    case success(matchCount: Int)
    case review(matchCount: Int)
    case failure(String)
}

enum AppFailure: LocalizedError {
    case invalidSource
    case unsupportedSource(String)
    case missingWorkbookData(String)
    case invalidTime(String)
    case invalidAIConfiguration(String)
    case invalidAIResponse(String)
    case calendarAccessDenied
    case calendarNotFound(String)
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "The sheet link or workbook path is invalid."
        case .unsupportedSource(let value):
            return "Unsupported source: \(value)"
        case .missingWorkbookData(let value):
            return "Workbook data is missing: \(value)"
        case .invalidTime(let value):
            return "Invalid time setting: \(value)"
        case .invalidAIConfiguration(let value):
            return "AI parser configuration is incomplete: \(value)"
        case .invalidAIResponse(let value):
            return "AI parser returned invalid data: \(value)"
        case .calendarAccessDenied:
            return "Calendar access was denied."
        case .calendarNotFound(let name):
            return "Calendar not found: \(name)"
        case .syncFailed(let message):
            return message
        }
    }
}

enum CalendarAccessState: Equatable {
    case unknown
    case notDetermined
    case granted
    case denied
    case restricted

    var hasUsableAccess: Bool {
        self == .granted
    }

    var promptButtonTitle: String {
        switch self {
        case .notDetermined:
            return "Grant Calendar Access"
        case .denied, .restricted:
            return "Open Calendar Settings"
        case .granted, .unknown:
            return "Grant Calendar Access"
        }
    }

    var helperText: String? {
        switch self {
        case .unknown:
            return nil
        case .notDetermined:
            return "Calendar access is required before \(appDisplayName) can load or update your calendars. Click Grant Calendar Access to continue."
        case .granted:
            return nil
        case .denied:
            return "Calendar access is off for \(appDisplayName). Open Calendar Settings, then enable access and return to the app."
        case .restricted:
            return "Calendar access is restricted on this Mac. Check Screen Time, MDM, or device privacy restrictions."
        }
    }
}

private func currentCalendarAccessState() -> CalendarAccessState {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(macOS 14.0, *) {
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    } else {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }
}

private let monthAliases: [String: Int] = [
    "january": 1, "jan": 1,
    "february": 2, "feb": 2,
    "march": 3, "mar": 3,
    "april": 4, "apri": 4, "apr": 4,
    "may": 5,
    "june": 6, "jun": 6,
    "july": 7, "jul": 7,
    "august": 8, "aug": 8, "ang": 8,
    "september": 9, "sept": 9, "sep": 9,
    "october": 10, "oct": 10,
    "november": 11, "nov": 11,
    "december": 12, "dec": 12
]

private let defaultOpenAIEndpointURL = "https://api.openai.com/v1/responses"
private let defaultOpenAIModel = "gpt-5.4"
private let defaultDeepSeekEndpointURL = "https://api.deepseek.com/chat/completions"
private let defaultDeepSeekModel = "deepseek-chat"
private let defaultKimiEndpointURL = "https://api.moonshot.cn/v1/chat/completions"
private let defaultKimiModel = "moonshot-v1-8k"
private let defaultKimiImageModel = "moonshot-v1-8k-vision-preview"
private let defaultAnthropicEndpointURL = "https://api.anthropic.com/v1/messages"
private let defaultAnthropicModel = "claude-sonnet-4-20250514"
private let defaultGeminiEndpointURL = "https://generativelanguage.googleapis.com/v1beta/models"
private let defaultGeminiModel = "gemini-2.5-flash"
private let defaultOpenRouterEndpointURL = "https://openrouter.ai/api/v1/chat/completions"
private let defaultOpenRouterModel = "openai/gpt-4o-mini"
private let defaultAIProvider: AIProvider = .openAI
private let defaultAIEndpointURL = defaultOpenAIEndpointURL
private let defaultAIModel = defaultOpenAIModel
private let aiKeychainService = "PPMSCalendarSync"
private let aiKeychainAccount = "ai-api-key"
private let aiAverageConfidenceReviewThreshold = 0.90
private let aiMinimumConfidenceReviewThreshold = 0.78

private func builtinSlotRules() -> [SlotRule] {
    [
        SlotRule(sheetLabel: "8:30-1pm", start: "08:30", end: "13:00", endsNextDay: false),
        SlotRule(sheetLabel: "1pm-6pm", start: "13:00", end: "18:00", endsNextDay: false),
        SlotRule(sheetLabel: "overnight", start: "18:00", end: "08:30", endsNextDay: true),
    ]
}

private func defaultWorkdayHours() -> WorkdayHours {
    WorkdayHours(start: "10:00", end: "20:00")
}

private func defaultSources() -> [SourceItem] {
    [
        SourceItem(
            name: "ppms",
            source: "https://docs.google.com/spreadsheets/d/1J7XCLh20n1qBkhBNyfF0XwnM2vItuOlGl6j5iQR1aVg/edit?usp=sharing",
            bookingID: "LJZ",
            calendar: "Experiment"
        )
    ]
}

private func inferAIProvider(fromEndpoint endpoint: String) -> AIProvider {
    let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.contains("deepseek.com") {
        return .deepSeek
    }
    if normalized.contains("moonshot.cn") || normalized.contains("moonshot.ai") {
        return .kimi
    }
    if normalized.contains("anthropic.com") {
        return .anthropic
    }
    if normalized.contains("generativelanguage.googleapis.com") || normalized.contains("googleapis.com") {
        return .gemini
    }
    if normalized.contains("openrouter.ai") {
        return .openRouter
    }
    if normalized.isEmpty || normalized.contains("api.openai.com") {
        return .openAI
    }
    return .custom
}

private enum AIRequestStyle {
    case responses
    case chatCompletions
    case anthropicMessages
    case geminiGenerateContent
}

private struct AIServiceConfiguration {
    var provider: AIProvider
    var endpointURL: URL
    var apiKey: String
    var model: String

    var requestStyle: AIRequestStyle {
        switch provider {
        case .openAI:
            return .responses
        case .deepSeek, .kimi, .openRouter:
            return .chatCompletions
        case .anthropic:
            return .anthropicMessages
        case .gemini:
            return .geminiGenerateContent
        case .custom:
            let endpoint = endpointURL.absoluteString.lowercased()
            if endpoint.contains("/chat/completions") {
                return .chatCompletions
            }
            if endpoint.contains("anthropic.com") {
                return .anthropicMessages
            }
            if endpoint.contains("generativelanguage.googleapis.com") || endpoint.contains("googleapis.com") {
                return .geminiGenerateContent
            }
            return .responses
        }
    }

    private var manualModelOverride: String? {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedModel.isEmpty ? nil : normalizedModel
    }

    func resolvedModel(forImageParsing: Bool) -> String {
        if let manualModelOverride {
            return manualModelOverride
        }
        return forImageParsing ? provider.automaticImageModel : provider.automaticSheetModel
    }

    func configurationForRequest(isImageParsing: Bool) -> AIServiceConfiguration {
        var adjusted = self
        adjusted.model = resolvedModel(forImageParsing: isImageParsing)
        return adjusted
    }
}

private final class KeychainStore {
    static func loadAIAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: aiKeychainService,
            kSecAttrAccount as String: aiKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func saveAIAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: aiKeychainService,
            kSecAttrAccount as String: aiKeychainAccount
        ]

        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

private final class SettingsStore {
    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return AppSettings(
                sources: defaultSources(),
                workdayHours: defaultWorkdayHours(),
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

        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings(
                sources: defaultSources(),
                workdayHours: defaultWorkdayHours(),
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

        let legacyObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let needsWorkdayMigration = legacyObject?["workdayHours"] == nil
        if needsWorkdayMigration {
            var migrated = settings
            migrated.workdayHours = defaultWorkdayHours()
            saveSettings(migrated)
            return migrated
        }

        return settings
    }

    static func saveSettings(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL)
        } catch {
        }
    }

    static func loadState() -> SyncState {
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else {
            return SyncState(events: [:])
        }
        return state
    }

    static func saveState(_ state: SyncState) {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL)
        } catch {
        }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var currentText = ""
    private var insideSI = false
    private var insideTextNode = false

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "si" {
            insideSI = true
            currentText = ""
        } else if elementName == "t", insideSI {
            insideTextNode = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideSI, insideTextNode {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            insideTextNode = false
        } else if elementName == "si" {
            strings.append(currentText)
            insideSI = false
            currentText = ""
        }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    private(set) var sheets: [WorkbookSheet] = []

    func parse(data: Data) -> [WorkbookSheet] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return sheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName == "sheet" else { return }
        if let name = attributeDict["name"], let rid = attributeDict["r:id"] {
            sheets.append(
                WorkbookSheet(
                    name: name,
                    relationshipID: rid,
                    state: attributeDict["state"] ?? "visible"
                )
            )
        }
    }
}

private final class RelationshipParser: NSObject, XMLParserDelegate {
    private(set) var mapping: [String: String] = [:]

    func parse(data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return mapping
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName == "Relationship" else { return }
        guard let type = attributeDict["Type"], type.contains("/worksheet"),
              let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        mapping[id] = target
    }
}

private final class WorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var cellsByRow: [Int: [Int: String]] = [:]
    private(set) var maxRow = 0
    private(set) var maxColumn = 0

    private var currentReference = ""
    private var currentType = ""
    private var currentValue = ""
    private var captureValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parse(data: Data) -> WorksheetParser {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return self
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "c" {
            currentReference = attributeDict["r"] ?? ""
            currentType = attributeDict["t"] ?? ""
            currentValue = ""
        } else if elementName == "v" || elementName == "t" {
            captureValue = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureValue {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "v" || elementName == "t" {
            captureValue = false
        } else if elementName == "c" {
            guard let (row, column) = decodeCellReference(currentReference) else { return }
            var resolved = currentValue
            if currentType == "s", let index = Int(currentValue), sharedStrings.indices.contains(index) {
                resolved = sharedStrings[index]
            }
            if !resolved.isEmpty {
                var rowCells = cellsByRow[row] ?? [:]
                rowCells[column] = resolved
                cellsByRow[row] = rowCells
                maxRow = max(maxRow, row)
                maxColumn = max(maxColumn, column)
            }
        }
    }
}

private struct XLSXPackage {
    let rootURL: URL

    init(xlsxURL: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppms-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", xlsxURL.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw AppFailure.syncFailed("Could not unpack workbook.")
        }
        rootURL = tempDir
    }

    func data(at relativePath: String) throws -> Data {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw AppFailure.missingWorkbookData(relativePath)
        }
        return data
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct ParsedWorkbookSheet {
    var name: String
    var year: Int?
    var month: Int?
    var worksheet: WorksheetParser
}

private struct WorkbookSnapshot: Encodable {
    var sourceName: String
    var sourceLink: String
    var bookingID: String
    var calendar: String
    var timezone: String
    var defaultWorkday: WorkbookSnapshotWorkday
    var sheets: [WorkbookSnapshotSheet]
}

private struct WorkbookSnapshotWorkday: Encodable {
    var start: String
    var end: String
}

private struct WorkbookSnapshotSheet: Encodable {
    var name: String
    var rows: [WorkbookSnapshotRow]
}

private struct WorkbookSnapshotRow: Encodable {
    var rowNumber: Int
    var cells: [WorkbookSnapshotCell]
}

private struct WorkbookSnapshotCell: Encodable {
    var column: String
    var value: String
}

private struct AINormalizationPayload: Decodable {
    var parserSummary: String
    var occurrences: [AINormalizedOccurrence]

    enum CodingKeys: String, CodingKey {
        case parserSummary = "parser_summary"
        case occurrences
    }
}

private func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
        guard let value = dictionary[key] else { continue }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
    }
    return nil
}

private func boolValue(in dictionary: [String: Any], keys: [String]) -> Bool? {
    for key in keys {
        guard let value = dictionary[key] else { continue }
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                continue
            }
        }
    }
    return nil
}

private func doubleValue(in dictionary: [String: Any], keys: [String]) -> Double? {
    for key in keys {
        guard let value = dictionary[key] else { continue }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String, let parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
    }
    return nil
}

private struct AINormalizedOccurrence: Decodable {
    var sheetName: String
    var cellReference: String
    var startISO: String?
    var endISO: String?
    var dateText: String?
    var timeText: String?
    var startTimeText: String?
    var endTimeText: String?
    var lessonText: String?
    var allDay: Bool
    var confidence: Double
    var explanation: String

    enum CodingKeys: String, CodingKey {
        case sheetName = "sheet_name"
        case cellReference = "cell_reference"
        case startISO = "start_iso"
        case endISO = "end_iso"
        case dateText = "date_text"
        case timeText = "time_text"
        case startTimeText = "start_time_text"
        case endTimeText = "end_time_text"
        case lessonText = "lesson_text"
        case allDay = "all_day"
        case confidence
        case explanation
    }
}

private struct AINormalizationResult {
    var occurrences: [SlotOccurrence]
    var notes: [String]
    var workbookFingerprint: String
    var averageConfidence: Double?
    var minimumConfidence: Double?
    var reviewRequired: Bool
}

private struct AIImageAttachment {
    var data: Data
    var mimeType: String
}

private struct LocalImageOCRWord {
    var page: Int
    var block: Int
    var paragraph: Int
    var line: Int
    var left: Int
    var top: Int
    var width: Int
    var height: Int
    var confidence: Double
    var text: String

    var right: Int { left + width }
    var bottom: Int { top + height }
    var centerX: Double { Double(left + width / 2) }
    var centerY: Double { Double(top + height / 2) }
    var lineKey: String { "\(page)-\(block)-\(paragraph)-\(line)" }
}

private struct LocalImageOCRLine {
    var left: Int
    var top: Int
    var words: [LocalImageOCRWord]
    var text: String
}

private struct LocalDateHeader {
    var text: String
    var date: Date
    var centerX: Double
    var centerY: Double
}

private struct LocalColorRGB {
    var red: Double
    var green: Double
    var blue: Double
}

private struct LocalColorComponent {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int
    var pixelCount: Int

    var centerX: Double { Double(left + right) / 2.0 }
    var centerY: Double { Double(top + bottom) / 2.0 }
}

private struct LocalTimetableParseResult {
    var occurrences: [SlotOccurrence]
    var notes: [String]
}

private struct ResolvedOccurrenceRange {
    var start: Date
    var end: Date
    var requiresReview: Bool
}

private struct ParserSelection {
    var occurrences: [SlotOccurrence]
    var label: String
    var notes: [String]
    var reviewRequired: Bool
    var workbookFingerprint: String?
    var averageConfidence: Double?
    var minimumConfidence: Double?
}

private struct ResponsesAPIEnvelope: Decodable {
    var outputText: String?
    var output: [ResponsesAPIOutput]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }
}

private struct ResponsesAPIOutput: Decodable {
    var content: [ResponsesAPIContent]?
}

private struct ResponsesAPIContent: Decodable {
    var type: String
    var text: String?
}

private struct ChatCompletionsEnvelope: Decodable {
    var choices: [ChatCompletionChoice]
}

private struct ChatCompletionChoice: Decodable {
    var message: ChatCompletionMessage
}

private struct ChatCompletionMessage: Decodable {
    var content: String?
}

private struct AnthropicMessagesEnvelope: Decodable {
    var content: [AnthropicContentBlock]
}

private struct AnthropicContentBlock: Decodable {
    var type: String
    var text: String?
}

private struct GeminiGenerateContentEnvelope: Decodable {
    var candidates: [GeminiCandidate]?
}

private struct GeminiCandidate: Decodable {
    var content: GeminiContent?
}

private struct GeminiContent: Decodable {
    var parts: [GeminiPart]?
}

private struct GeminiPart: Decodable {
    var text: String?
}

private struct LocalTimetableImageParser {
    private static var debugLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["PPMS_DEBUG_LOCAL_IMAGE"] == "1"
    }

    private static func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        fputs("[local-image] \(message)\n", stderr)
    }

    private struct BitmapSampler {
        let bitmap: NSBitmapImageRep
        let width: Int
        let height: Int

        init?(imageURL: URL) {
            guard let data = try? Data(contentsOf: imageURL),
                  let bitmap = NSBitmapImageRep(data: data) else {
                return nil
            }
            self.bitmap = bitmap
            self.width = bitmap.pixelsWide
            self.height = bitmap.pixelsHigh
        }

        func color(atX x: Int, y: Int) -> LocalColorRGB? {
            guard (0..<width).contains(x), (0..<height).contains(y) else {
                return nil
            }
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return nil
            }
            return LocalColorRGB(
                red: Double(color.redComponent * 255.0),
                green: Double(color.greenComponent * 255.0),
                blue: Double(color.blueComponent * 255.0)
            )
        }
    }

    static func parse(
        source: SourceItem,
        workdayHours: WorkdayHours,
        imageURL: URL,
        timeZone: TimeZone
    ) throws -> LocalTimetableParseResult? {
        guard let bitmap = BitmapSampler(imageURL: imageURL) else {
            return nil
        }
        let denseWords = try parseOCRWords(imageURL: imageURL, pageSegmentationMode: 11)
        guard !denseWords.isEmpty else {
            debugLog("No OCR words from PSM 11.")
            return nil
        }
        debugLog("PSM11 words: \(denseWords.count)")
        let rowWords = try parseOCRWords(imageURL: imageURL, pageSegmentationMode: 4)
        debugLog("PSM4 words: \(rowWords.count)")
        let dateRows = buildDateRows(from: denseWords, timeZone: timeZone)
        guard !dateRows.isEmpty else {
            debugLog("No date rows recognized.")
            return nil
        }
        debugLog("Date rows: \(dateRows.count)")
        guard let legendWord = findLegendWord(for: source.bookingID, in: denseWords) else {
            debugLog("Legend word for \(source.bookingID) not found.")
            return nil
        }
        debugLog("Legend word: \(legendWord.text) @ \(legendWord.left),\(legendWord.top)")
        guard let targetColor = sampleLegendColor(around: legendWord, bitmap: bitmap) else {
            debugLog("Legend color sampling failed.")
            return nil
        }
        debugLog(String(format: "Legend color: %.1f %.1f %.1f", targetColor.red, targetColor.green, targetColor.blue))
        let components = detectTargetComponents(
            bitmap: bitmap,
            targetColor: targetColor,
            minimumY: max(170, legendWord.bottom + 20)
        )
        guard !components.isEmpty else {
            debugLog("No target color components detected.")
            return nil
        }
        debugLog("Components: \(components.count)")
        let rowTemplates = buildRowTemplates(from: rowWords, dateRows: dateRows)
        debugLog("Row templates: \(rowTemplates.count)")
        var occurrences: [SlotOccurrence] = []

        for component in components {
            guard let weekRow = dateRows.last(where: { ($0.first?.centerY ?? 0) <= component.centerY }) else {
                debugLog("Could not map week row for component at \(Int(component.centerX)),\(Int(component.centerY)).")
                return nil
            }
            guard let dateHeader = weekRow.min(by: { abs($0.centerX - component.centerX) < abs($1.centerX - component.centerX) }) else {
                debugLog("Could not map date header for component at \(Int(component.centerX)),\(Int(component.centerY)).")
                return nil
            }
            let text = denseWords
                .filter { intersects(word: $0, component: component, padding: 16) }
                .sorted { lhs, rhs in
                    if lhs.top == rhs.top {
                        return lhs.left < rhs.left
                    }
                    return lhs.top < rhs.top
                }
                .map(\.text)
                .joined(separator: " ")

            var times = extractLooseClocks(from: text)
            debugLog("Raw \(dateHeader.text): \(text)")
            debugLog("Raw times \(dateHeader.text): \(times)")
            let weekRowY = weekRow.first?.centerY ?? component.centerY
            let template = preferredRowTemplate(
                for: component,
                weekRowY: weekRowY,
                templates: rowTemplates
            )
            if times.count < 2 {
                if let template {
                    debugLog("Template \(dateHeader.text): \(template.start)-\(template.end)")
                    if times.isEmpty {
                        times = [template.start, template.end]
                    } else {
                        times = deduplicatedSortedClocks(times + [template.start, template.end])
                    }
                }
            }
            let resolvedClocks = resolveComponentClocks(
                extracted: times,
                template: template
            )
            debugLog("Resolved times \(dateHeader.text): \(resolvedClocks.map { [$0.start, $0.end] } ?? [])")
            guard let resolvedClocks else {
                debugLog("Could not resolve times for \(dateHeader.text) component text: \(text)")
                return nil
            }
            let startClock = resolvedClocks.start
            let endClock = resolvedClocks.end
            guard let start = try? buildDate(from: dateHeader.date, timeString: startClock, in: timeZone),
                  let rawEnd = try? buildDate(from: dateHeader.date, timeString: endClock, in: timeZone) else {
                return nil
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let end = rawEnd > start ? rawEnd : (calendar.date(byAdding: .day, value: 1, to: rawEnd) ?? rawEnd)
            occurrences.append(
                SlotOccurrence(
                    start: start,
                    end: end,
                    sheetName: "image",
                    cellReference: "\(Int(component.centerX))x\(Int(component.centerY))",
                    slotLabel: "local-image",
                    isAllDay: false
                )
            )
            debugLog("Mapped \(dateHeader.text) -> \(startClock)-\(endClock)")
        }

        guard occurrences.count == components.count else {
            debugLog("Occurrence count mismatch: \(occurrences.count) vs \(components.count)")
            return nil
        }
        occurrences.sort { $0.start < $1.start }
        return LocalTimetableParseResult(
            occurrences: occurrences,
            notes: [
                "Recognized a structured color-coded timetable locally for more consistent image extraction.",
                "Matched \(occurrences.count) lesson(s) using the legend color and OCR date/time anchors."
            ]
        )
    }

    private static func parseOCRWords(
        imageURL: URL,
        pageSegmentationMode: Int
    ) throws -> [LocalImageOCRWord] {
        guard let tesseractPath = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tesseractPath)
        process.arguments = [
            imageURL.path,
            "stdout",
            "-l", "eng",
            "--psm", String(pageSegmentationMode),
            "tsv"
        ]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let tsv = String(data: data, encoding: .utf8) else {
            return []
        }

        return tsv
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .compactMap { line -> LocalImageOCRWord? in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard columns.count >= 12, columns[0] == "5" else {
                    return nil
                }
                guard
                    let page = Int(columns[1]),
                    let block = Int(columns[2]),
                    let paragraph = Int(columns[3]),
                    let line = Int(columns[4]),
                    let left = Int(columns[6]),
                    let top = Int(columns[7]),
                    let width = Int(columns[8]),
                    let height = Int(columns[9]),
                    let confidence = Double(columns[10])
                else {
                    return nil
                }
                let text = columns[11].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }
                return LocalImageOCRWord(
                    page: page,
                    block: block,
                    paragraph: paragraph,
                    line: line,
                    left: left,
                    top: top,
                    width: width,
                    height: height,
                    confidence: confidence,
                    text: text
                )
            }
    }

    private static func buildDateRows(
        from words: [LocalImageOCRWord],
        timeZone: TimeZone
    ) -> [[LocalDateHeader]] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/M/d"

        let headers = words.compactMap { word -> LocalDateHeader? in
            guard word.text.range(of: #"^20\d{2}/\d{1,2}/\d{1,2}$"#, options: .regularExpression) != nil,
                  let date = formatter.date(from: word.text) else {
                return nil
            }
            return LocalDateHeader(
                text: word.text,
                date: date,
                centerX: word.centerX,
                centerY: word.centerY
            )
        }
        .sorted { lhs, rhs in
            if lhs.centerY == rhs.centerY {
                return lhs.centerX < rhs.centerX
            }
            return lhs.centerY < rhs.centerY
        }

        var rows: [[LocalDateHeader]] = []
        for header in headers {
            if rows.isEmpty || abs((rows.last?.first?.centerY ?? 0) - header.centerY) > 40 {
                rows.append([header])
            } else {
                rows[rows.count - 1].append(header)
            }
        }
        return rows.map { $0.sorted { $0.centerX < $1.centerX } }
    }

    private static func findLegendWord(
        for bookingID: String,
        in words: [LocalImageOCRWord]
    ) -> LocalImageOCRWord? {
        let target = normalizedLetters(bookingID)
        guard !target.isEmpty else {
            return nil
        }
        return words
            .filter { normalizedLetters($0.text).contains(target) || normalizedLetters($0.text).hasSuffix(target) }
            .max(by: { lhs, rhs in lhs.confidence < rhs.confidence })
    }

    private static func sampleLegendColor(
        around word: LocalImageOCRWord,
        bitmap: BitmapSampler
    ) -> LocalColorRGB? {
        var samples: [LocalColorRGB] = []
        let xRange = max(0, word.left - 16)...min(bitmap.width - 1, word.right + 16)
        let yRange = max(0, word.top - 8)...min(bitmap.height - 1, word.bottom + 8)
        for y in stride(from: yRange.lowerBound, through: yRange.upperBound, by: 2) {
            for x in stride(from: xRange.lowerBound, through: xRange.upperBound, by: 2) {
                guard let color = bitmap.color(atX: x, y: y) else { continue }
                let brightness = color.red + color.green + color.blue
                if brightness < 740 && max(color.red, color.green, color.blue) > 120 {
                    samples.append(color)
                }
            }
        }
        guard !samples.isEmpty else {
            return nil
        }
        let count = Double(samples.count)
        return LocalColorRGB(
            red: samples.reduce(0) { $0 + $1.red } / count,
            green: samples.reduce(0) { $0 + $1.green } / count,
            blue: samples.reduce(0) { $0 + $1.blue } / count
        )
    }

    private static func detectTargetComponents(
        bitmap: BitmapSampler,
        targetColor: LocalColorRGB,
        minimumY: Int
    ) -> [LocalColorComponent] {
        let step = 4
        let gridWidth = (bitmap.width + step - 1) / step
        let gridHeight = (bitmap.height + step - 1) / step
        var mask = Array(repeating: false, count: gridWidth * gridHeight)

        for gridY in 0..<gridHeight {
            let y = min(bitmap.height - 1, gridY * step + step / 2)
            for gridX in 0..<gridWidth {
                let x = min(bitmap.width - 1, gridX * step + step / 2)
                guard let color = bitmap.color(atX: x, y: y) else { continue }
                if colorDistance(color, targetColor) < 70, y > minimumY {
                    mask[gridY * gridWidth + gridX] = true
                }
            }
        }

        var visited = Array(repeating: false, count: mask.count)
        var components: [LocalColorComponent] = []

        for gridY in 0..<gridHeight {
            for gridX in 0..<gridWidth {
                let startIndex = gridY * gridWidth + gridX
                guard mask[startIndex], !visited[startIndex] else { continue }
                var queue = [(gridX, gridY)]
                visited[startIndex] = true
                var positions: [(Int, Int)] = []
                var cursor = 0

                while cursor < queue.count {
                    let (currentX, currentY) = queue[cursor]
                    cursor += 1
                    positions.append((currentX, currentY))

                    let neighbors = [
                        (currentX + 1, currentY),
                        (currentX - 1, currentY),
                        (currentX, currentY + 1),
                        (currentX, currentY - 1)
                    ]
                    for (nextX, nextY) in neighbors {
                        guard (0..<gridWidth).contains(nextX), (0..<gridHeight).contains(nextY) else { continue }
                        let nextIndex = nextY * gridWidth + nextX
                        guard mask[nextIndex], !visited[nextIndex] else { continue }
                        visited[nextIndex] = true
                        queue.append((nextX, nextY))
                    }
                }

                guard positions.count >= 80 else { continue }
                let minX = positions.map(\.0).min() ?? 0
                let maxX = positions.map(\.0).max() ?? 0
                let minY = positions.map(\.1).min() ?? 0
                let maxY = positions.map(\.1).max() ?? 0
                components.append(
                    LocalColorComponent(
                        left: minX * step,
                        top: minY * step,
                        right: maxX * step,
                        bottom: maxY * step,
                        pixelCount: positions.count
                    )
                )
            }
        }

        return components.sorted {
            if $0.top == $1.top {
                return $0.left < $1.left
            }
            return $0.top < $1.top
        }
    }

    private static func buildRowTemplates(
        from words: [LocalImageOCRWord],
        dateRows: [[LocalDateHeader]]
    ) -> [(offset: Double, start: String, end: String)] {
        let grouped = Dictionary(grouping: words, by: \.lineKey)
        return grouped.values.compactMap { group in
            let sorted = group.sorted { $0.left < $1.left }
            guard let left = sorted.map(\.left).min(), left < 250,
                  let top = sorted.map(\.top).min() else {
                return nil
            }
            let text = sorted.map(\.text).joined(separator: " ")
            let times = extractLooseClocks(from: text)
            guard times.count == 2,
                  let startMinutes = minutesSinceMidnight(times[0]),
                  let endMinutes = minutesSinceMidnight(times[1]),
                  startMinutes >= 6 * 60,
                  endMinutes > startMinutes else {
                return nil
            }
            guard let weekRow = dateRows.last(where: { ($0.first?.centerY ?? 0) <= Double(top) }) else {
                return nil
            }
            return (offset: Double(top) - (weekRow.first?.centerY ?? 0), start: times[0], end: times[1])
        }
    }

    private static func nearestRowTemplate(
        to relativeY: Double,
        templates: [(offset: Double, start: String, end: String)]
    ) -> (offset: Double, start: String, end: String)? {
        guard let candidate = templates.min(by: { abs($0.offset - relativeY) < abs($1.offset - relativeY) }) else {
            return nil
        }
        return abs(candidate.offset - relativeY) < 32 ? candidate : nil
    }

    private static func preferredRowTemplate(
        for component: LocalColorComponent,
        weekRowY: Double,
        templates: [(offset: Double, start: String, end: String)]
    ) -> (offset: Double, start: String, end: String)? {
        let topAligned = nearestRowTemplate(
            to: Double(component.top) - weekRowY + 10,
            templates: templates
        )
        if let topAligned {
            return topAligned
        }
        return nearestRowTemplate(
            to: component.centerY - weekRowY,
            templates: templates
        )
    }

    private static func resolveComponentClocks(
        extracted: [String],
        template: (offset: Double, start: String, end: String)?
    ) -> (start: String, end: String)? {
        let unique = deduplicatedSortedClocks(extracted)
        guard !unique.isEmpty else {
            guard let template else { return nil }
            return (template.start, template.end)
        }

        if unique.count == 1 {
            guard let template else { return nil }
            return (template.start, template.end)
        }

        guard let template else {
            return (unique[0], unique[unique.count - 1])
        }

        if unique.contains(template.start), unique.contains(template.end) {
            return (template.start, template.end)
        }

        let candidatePairs = unique.enumerated().flatMap { lhs in
            unique.enumerated().compactMap { rhs -> (String, String)? in
                guard rhs.offset > lhs.offset else { return nil }
                return (lhs.element, rhs.element)
            }
        }

        let templateStart = minutesSinceMidnight(template.start) ?? 0
        let templateEnd = minutesSinceMidnight(template.end) ?? 0
        let templateDuration = max(templateEnd - templateStart, 0)

        let bestPair = candidatePairs.min { lhs, rhs in
            scoreClockPair(lhs, templateStart: templateStart, templateEnd: templateEnd, templateDuration: templateDuration)
            < scoreClockPair(rhs, templateStart: templateStart, templateEnd: templateEnd, templateDuration: templateDuration)
        }

        guard let bestPair else {
            return (template.start, template.end)
        }

        let bestScore = scoreClockPair(
            bestPair,
            templateStart: templateStart,
            templateEnd: templateEnd,
            templateDuration: templateDuration
        )

        if bestScore <= 150 {
            return bestPair
        }
        return (template.start, template.end)
    }

    private static func scoreClockPair(
        _ pair: (String, String),
        templateStart: Int,
        templateEnd: Int,
        templateDuration: Int
    ) -> Int {
        let start = minutesSinceMidnight(pair.0) ?? 0
        let end = minutesSinceMidnight(pair.1) ?? 0
        let duration = max(end - start, 0)
        return abs(start - templateStart) + abs(end - templateEnd) + abs(duration - templateDuration) * 2
    }

    private static func intersects(
        word: LocalImageOCRWord,
        component: LocalColorComponent,
        padding: Int
    ) -> Bool {
        let left = component.left - padding
        let right = component.right + padding
        let top = component.top - padding
        let bottom = component.bottom + padding
        return word.left >= left &&
            word.left <= right &&
            Int(word.centerY) >= top &&
            Int(word.centerY) <= bottom
    }

    private static func extractLooseClocks(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: ";", with: ":")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "o", with: "0")
            .replacingOccurrences(of: "i", with: "1")

        var clocks: [String] = []
        let standard = try! NSRegularExpression(pattern: #"(\d{1,2})[:](\d{2})"#)
        for match in standard.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            guard let hourRange = Range(match.range(at: 1), in: normalized),
                  let minuteRange = Range(match.range(at: 2), in: normalized),
                  let hour = Int(normalized[hourRange]),
                  let minute = Int(normalized[minuteRange]),
                  (0...23).contains(hour),
                  (0...59).contains(minute) else {
                continue
            }
            clocks.append(String(format: "%02d:%02d", hour, minute))
        }

        let compact = try! NSRegularExpression(pattern: #"(?<!\d)(\d{2})(\d{2})(?!\d)"#)
        for match in compact.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            guard let hourRange = Range(match.range(at: 1), in: normalized),
                  let minuteRange = Range(match.range(at: 2), in: normalized),
                  let hour = Int(normalized[hourRange]),
                  let minute = Int(normalized[minuteRange]),
                  (6...23).contains(hour),
                  [0, 15, 30, 45].contains(minute) else {
                continue
            }
            clocks.append(String(format: "%02d:%02d", hour, minute))
        }

        return deduplicatedSortedClocks(clocks)
    }

    private static func deduplicatedSortedClocks(_ clocks: [String]) -> [String] {
        var unique: [String] = []
        for clock in clocks {
            if !unique.contains(clock) {
                unique.append(clock)
            }
        }
        return unique.sorted {
            (minutesSinceMidnight($0) ?? 0) < (minutesSinceMidnight($1) ?? 0)
        }
    }

    private static func minutesSinceMidnight(_ clock: String) -> Int? {
        let pieces = clock.split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]),
              let minute = Int(pieces[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private static func normalizedLetters(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func colorDistance(_ lhs: LocalColorRGB, _ rhs: LocalColorRGB) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }
}

private struct AIWorkbookNormalizer {
    private enum ImageExtractionStyle {
        case directTimestamps
        case visibleFields
    }

    static func normalizeImage(
        source: SourceItem,
        workdayHours: WorkdayHours,
        imageURL: URL,
        configuration: AIServiceConfiguration,
        timeZone: TimeZone
    ) async throws -> AINormalizationResult {
        guard let attachment = try makeImageAttachment(from: imageURL) else {
            throw AppFailure.unsupportedSource(imageURL.path)
        }

        let fingerprintInput = [
            source.name,
            source.source,
            source.bookingID,
            source.calendar,
            workdayHours.start,
            workdayHours.end,
            String(attachment.data.count)
        ].joined(separator: "|")
        let workbookFingerprint = digest(fingerprintInput + digest(attachment.data.base64EncodedString()))
        let ocrHints = localOCRHints(from: imageURL)

        let extractionStyle = imageExtractionStyle(for: configuration.provider)
        let instructions = imageInstructions(for: extractionStyle)

        let prompt = """
        Normalize this schedule image and return only matches for the configured booking ID.

        Source name: \(source.name)
        Booking ID to match: \(source.bookingID)
        Calendar: \(source.calendar)
        Timezone: \(timeZone.identifier)
        Default workday: \(workdayHours.start)-\(workdayHours.end)
        Important: the target booking may be referenced through a legend, color, or teacher/subject mapping instead of repeating the booking ID inside every occupied cell.
        \(ocrHints.map { "\nLocal OCR hints (secondary check only; trust the image if OCR conflicts):\n\($0)" } ?? "")
        """

        let schema = imageSchema(for: extractionStyle)

        let payloadData = try await requestPayload(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: attachment
        )

        let initial = try buildNormalizationResult(
            payloadData: payloadData,
            workbookFingerprint: workbookFingerprint,
            workdayHours: workdayHours,
            timeZone: timeZone
        )
        guard configuration.provider != .gemini, configuration.provider != .kimi, !initial.occurrences.isEmpty else {
            return applyImageProviderPolicy(to: initial, provider: configuration.provider)
        }

        let refined = try await refineImageNormalization(
            source: source,
            workdayHours: workdayHours,
            configuration: configuration,
            timeZone: timeZone,
            workbookFingerprint: workbookFingerprint,
            attachment: attachment,
            initial: initial,
            schema: schema,
            ocrHints: ocrHints
        )
        let preferred = preferredImageNormalization(initial: initial, refined: refined)
        return applyImageProviderPolicy(to: preferred, provider: configuration.provider)
    }

    static func normalize(
        source: SourceItem,
        workdayHours: WorkdayHours,
        sheets: [ParsedWorkbookSheet],
        configuration: AIServiceConfiguration,
        timeZone: TimeZone
    ) async throws -> AINormalizationResult {
        let snapshot = WorkbookSnapshot(
            sourceName: source.name,
            sourceLink: source.source,
            bookingID: source.bookingID,
            calendar: source.calendar,
            timezone: timeZone.identifier,
            defaultWorkday: WorkbookSnapshotWorkday(
                start: workdayHours.start,
                end: workdayHours.end
            ),
            sheets: sheets.map(snapshotSheet)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshotData = try encoder.encode(snapshot)
        guard let snapshotText = String(data: snapshotData, encoding: .utf8) else {
            throw AppFailure.invalidAIResponse("Could not encode workbook snapshot.")
        }
        let workbookFingerprint = digest(snapshotText)

        let instructions = """
        You normalize reservation spreadsheets into atomic calendar occurrences.
        Match only reservations that belong to the provided booking ID.
        Return one occurrence per directly observed occupied slot or day. Do not pre-merge adjacent matches.
        Use the supplied timezone for all timestamps.
        If the workbook only gives a date without explicit times, use the provided default workday start and end for that day and set all_day to false.
        If the workbook uses timed slots, use explicit times from the workbook whenever they are visible in the sheet.
        Do not invent bookings when the match is ambiguous. Return an empty occurrences array if nothing confidently matches.
        """

        let prompt = """
        Normalize this workbook and return only matches for the configured booking ID.

        Workbook snapshot JSON:
        \(snapshotText)
        """

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "parser_summary": [
                    "type": "string"
                ],
                "occurrences": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "sheet_name": ["type": "string"],
                            "cell_reference": ["type": "string"],
                            "start_iso": ["type": "string"],
                            "end_iso": ["type": "string"],
                            "all_day": ["type": "boolean"],
                            "confidence": ["type": "number"],
                            "explanation": ["type": "string"]
                        ],
                        "required": [
                            "sheet_name",
                            "cell_reference",
                            "start_iso",
                            "end_iso",
                            "all_day",
                            "confidence",
                            "explanation"
                        ]
                    ]
                ]
            ],
            "required": ["parser_summary", "occurrences"]
        ]

        let payloadData = try await requestPayload(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema
        )

        return try buildNormalizationResult(
            payloadData: payloadData,
            workbookFingerprint: workbookFingerprint,
            workdayHours: workdayHours,
            timeZone: timeZone
        )
    }

    private static func buildNormalizationResult(
        payloadData: Data,
        workbookFingerprint: String,
        workdayHours: WorkdayHours,
        timeZone: TimeZone
    ) throws -> AINormalizationResult {
        let payload = try parseNormalizationPayload(payloadData)

        var occurrences: [SlotOccurrence] = []
        var warnings: [String] = []
        var confidences: [Double] = []
        var requiresReview = false
        let calendar = Calendar(identifier: .gregorian)

        for item in payload.occurrences {
            guard let resolvedRange = resolveOccurrenceRange(
                item,
                workdayHours: workdayHours,
                calendar: calendar,
                timeZone: timeZone
            ) else {
                warnings.append("Skipped \(item.sheetName) \(item.cellReference): could not resolve the visible date/time.")
                continue
            }

            occurrences.append(
                SlotOccurrence(
                    start: resolvedRange.start,
                    end: resolvedRange.end,
                    sheetName: item.sheetName,
                    cellReference: item.cellReference,
                    slotLabel: item.allDay ? "default-workday" : "ai",
                    isAllDay: false
                )
            )
            confidences.append(item.confidence)
            requiresReview = requiresReview || resolvedRange.requiresReview
        }

        let averageConfidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        let minimumConfidence = confidences.min()
        var notes = [payload.parserSummary]
        if let averageConfidence {
            notes.append(String(format: "AI average confidence: %.2f", averageConfidence))
        }
        if let minimumConfidence {
            notes.append(String(format: "AI minimum confidence: %.2f", minimumConfidence))
        }
        if !warnings.isEmpty {
            notes.append("AI skipped \(warnings.count) invalid occurrence(s).")
        }
        if requiresReview {
            notes.append("AI needed local inference for part of the schedule. Review is recommended before syncing.")
        }
        if let anomaly = chronologicalAnomalyNote(for: occurrences) {
            notes.append(anomaly)
        }
        let reviewRequired = {
            guard !occurrences.isEmpty else { return false }
            if requiresReview {
                return true
            }
            if let averageConfidence, averageConfidence < aiAverageConfidenceReviewThreshold {
                return true
            }
            if let minimumConfidence, minimumConfidence < aiMinimumConfidenceReviewThreshold {
                return true
            }
            if chronologicalAnomalyNote(for: occurrences) != nil {
                return true
            }
            return false
        }()
        return AINormalizationResult(
            occurrences: occurrences,
            notes: notes,
            workbookFingerprint: workbookFingerprint,
            averageConfidence: averageConfidence,
            minimumConfidence: minimumConfidence,
            reviewRequired: reviewRequired
        )
    }

    private static func imageNormalizationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "parser_summary": [
                    "type": "string"
                ],
                "occurrences": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "sheet_name": ["type": "string"],
                            "cell_reference": ["type": "string"],
                            "date_text": ["type": "string"],
                            "time_text": ["type": "string"],
                            "start_time_text": ["type": "string"],
                            "end_time_text": ["type": "string"],
                            "lesson_text": ["type": "string"],
                            "start_iso": ["type": "string"],
                            "end_iso": ["type": "string"],
                            "all_day": ["type": "boolean"],
                            "confidence": ["type": "number"],
                            "explanation": ["type": "string"]
                        ],
                        "required": [
                            "sheet_name",
                            "cell_reference",
                            "date_text",
                            "time_text",
                            "start_time_text",
                            "end_time_text",
                            "lesson_text",
                            "start_iso",
                            "end_iso",
                            "all_day",
                            "confidence",
                            "explanation"
                        ]
                    ]
                ]
            ],
            "required": ["parser_summary", "occurrences"]
        ]
    }

    private static func resolveOccurrenceRange(
        _ item: AINormalizedOccurrence,
        workdayHours: WorkdayHours,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> ResolvedOccurrenceRange? {
        if let startISO = item.startISO,
           let endISO = item.endISO,
           let start = parseFlexibleISO8601(startISO, timeZone: timeZone),
           let end = parseFlexibleISO8601(endISO, timeZone: timeZone),
           end > start {
            if item.allDay,
               let workdayRange = buildWorkdayRange(
                on: start,
                workdayHours: workdayHours,
                calendar: calendar,
                timeZone: timeZone
               ) {
                return ResolvedOccurrenceRange(start: workdayRange.0, end: workdayRange.1, requiresReview: false)
            }
            return ResolvedOccurrenceRange(start: start, end: end, requiresReview: false)
        }

        guard let dateResolution = parseVisibleDate(item.dateText, timeZone: timeZone) else {
            return nil
        }
        if item.allDay {
            guard let workdayRange = buildWorkdayRange(
                on: dateResolution.date,
                workdayHours: workdayHours,
                calendar: calendar,
                timeZone: timeZone
            ) else {
                return nil
            }
            return ResolvedOccurrenceRange(
                start: workdayRange.0,
                end: workdayRange.1,
                requiresReview: dateResolution.requiresReview
            )
        }

        guard let timeRange = parseVisibleTimeRange(
            startTimeText: item.startTimeText,
            endTimeText: item.endTimeText,
            fallbackText: [item.timeText, item.lessonText].compactMap { $0 }.joined(separator: " ")
        ) else {
            guard let workdayRange = buildWorkdayRange(
                on: dateResolution.date,
                workdayHours: workdayHours,
                calendar: calendar,
                timeZone: timeZone
            ) else {
                return nil
            }
            return ResolvedOccurrenceRange(
                start: workdayRange.0,
                end: workdayRange.1,
                requiresReview: true
            )
        }

        guard let start = try? buildDate(from: dateResolution.date, timeString: timeRange.0, in: timeZone),
              let rawEnd = try? buildDate(from: dateResolution.date, timeString: timeRange.1, in: timeZone) else {
            return nil
        }
        let end = rawEnd > start ? rawEnd : (calendar.date(byAdding: .day, value: 1, to: rawEnd) ?? rawEnd)
        return ResolvedOccurrenceRange(
            start: start,
            end: end,
            requiresReview: dateResolution.requiresReview
        )
    }

    private static func parseVisibleDate(_ rawText: String?, timeZone: TimeZone) -> (date: Date, requiresReview: Bool)? {
        guard let rawText else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "年", with: "/")
            .replacingOccurrences(of: "月", with: "/")
            .replacingOccurrences(of: "日", with: "")
            .replacingOccurrences(of: ".", with: "/")
            .replacingOccurrences(of: "-", with: "/")

        if let components = firstMatch(
            in: normalized,
            pattern: #"(?<!\d)(20\d{2})\D{0,3}(\d{1,2})\D{0,3}(\d{1,2})(?!\d)"#
        ),
           let year = Int(components[0]),
           let month = Int(components[1]),
           let day = Int(components[2]),
           let date = makeVisibleDate(year: year, month: month, day: day, timeZone: timeZone) {
            return (date, false)
        }

        if let components = firstMatch(
            in: normalized,
            pattern: #"(?<!\d)(\d{1,2})\D{0,3}(\d{1,2})(?!\d)"#
        ),
           let month = Int(components[0]),
           let day = Int(components[1]) {
            let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
            if let date = makeVisibleDate(year: currentYear, month: month, day: day, timeZone: timeZone) {
                return (date, true)
            }
        }
        return nil
    }

    private static func parseVisibleTimeRange(
        startTimeText: String?,
        endTimeText: String?,
        fallbackText: String
    ) -> (String, String)? {
        if let start = normalizeVisibleClock(startTimeText),
           let end = normalizeVisibleClock(endTimeText) {
            return (start, end)
        }

        let candidates = extractVisibleClocks(from: fallbackText)
        guard candidates.count >= 2 else { return nil }
        return (candidates[0], candidates[1])
    }

    private static func normalizeVisibleClock(_ rawText: String?) -> String? {
        guard let rawText else { return nil }
        guard let match = firstMatch(
            in: rawText.replacingOccurrences(of: "：", with: ":"),
            pattern: #"(?<!\d)(\d{1,2}):(\d{2})(?!\d)"#
        ) else {
            return nil
        }
        guard let hour = Int(match[0]), let minute = Int(match[1]), (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func extractVisibleClocks(from rawText: String) -> [String] {
        let normalized = rawText.replacingOccurrences(of: "：", with: ":")
        let regex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2}):(\d{2})(?!\d)"#)
        let nsRange = NSRange(normalized.startIndex..., in: normalized)
        return regex.matches(in: normalized, range: nsRange).compactMap { match in
            guard let hourRange = Range(match.range(at: 1), in: normalized),
                  let minuteRange = Range(match.range(at: 2), in: normalized),
                  let hour = Int(normalized[hourRange]),
                  let minute = Int(normalized[minuteRange]),
                  (0...23).contains(hour),
                  (0...59).contains(minute) else {
                return nil
            }
            return String(format: "%02d:%02d", hour, minute)
        }
    }

    private static func localOCRHints(from imageURL: URL) -> String? {
        guard let tesseractPath = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tesseractPath)
        process.arguments = [imageURL.path, "stdout", "-l", "eng", "--psm", "6", "tsv"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let tsv = String(data: data, encoding: .utf8) else {
            return nil
        }

        struct OCRWord {
            var key: String
            var left: Int
            var top: Int
            var confidence: Double
            var text: String
        }

        var grouped: [String: [OCRWord]] = [:]
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 12,
                  columns[0] == "5",
                  let page = Int(columns[1]),
                  let block = Int(columns[2]),
                  let paragraph = Int(columns[3]),
                  let lineNumber = Int(columns[4]),
                  let left = Int(columns[6]),
                  let top = Int(columns[7]),
                  let confidence = Double(columns[10]) else {
                continue
            }
            let text = columns[11].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            let key = "\(page)-\(block)-\(paragraph)-\(lineNumber)"
            grouped[key, default: []].append(
                OCRWord(key: key, left: left, top: top, confidence: confidence, text: text)
            )
        }

        let lines: [(top: Int, left: Int, averageConfidence: Double, text: String)] = grouped.values.compactMap { words in
            let sorted = words.sorted { $0.left < $1.left }
            let text = sorted.map(\.text).joined(separator: " ")
            guard !text.isEmpty else {
                return nil
            }
            let averageConfidence = sorted.reduce(0.0) { $0 + $1.confidence } / Double(sorted.count)
            guard averageConfidence >= 45 else {
                return nil
            }
            return (
                top: sorted.map(\.top).min() ?? 0,
                left: sorted.map(\.left).min() ?? 0,
                averageConfidence: averageConfidence,
                text: text
            )
        }
        .sorted {
            if $0.top == $1.top {
                return $0.left < $1.left
            }
            return $0.top < $1.top
        }

        let datePattern = #"20\d{2}/\d{1,2}/\d{1,2}"#
        let timePattern = #"\d{1,2}:\d{2}"#

        let dateLines = lines.filter { $0.text.range(of: datePattern, options: .regularExpression) != nil }
        let timeLines = lines.filter { $0.text.range(of: timePattern, options: .regularExpression) != nil }

        var sections: [String] = []
        if !dateLines.isEmpty {
            sections.append(
                "Date header OCR:\n" + dateLines.prefix(6).map {
                    "- y\($0.top) x\($0.left): \($0.text)"
                }.joined(separator: "\n")
            )
        }
        if !timeLines.isEmpty {
            sections.append(
                "Time OCR:\n" + timeLines.prefix(12).map {
                    "- y\($0.top) x\($0.left): \($0.text)"
                }.joined(separator: "\n")
            )
        }
        let output = sections.joined(separator: "\n")
        return output.isEmpty ? nil : output
    }

    private static func firstMatch(in source: String, pattern: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: pattern)
        let nsRange = NSRange(source.startIndex..., in: source)
        guard let match = regex.firstMatch(in: source, range: nsRange) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: source) else {
                return nil
            }
            return String(source[range])
        }
    }

    private static func makeVisibleDate(year: Int, month: Int, day: Int, timeZone: TimeZone) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = timeZone
        return calendar.date(from: components)
    }

    private static func refineImageNormalization(
        source: SourceItem,
        workdayHours: WorkdayHours,
        configuration: AIServiceConfiguration,
        timeZone: TimeZone,
        workbookFingerprint: String,
        attachment: AIImageAttachment,
        initial: AINormalizationResult,
        schema: [String: Any],
        ocrHints: String?
    ) async throws -> AINormalizationResult {
        let initialOccurrences: [[String: Any]] = initial.occurrences.map { occurrence in
            [
                "start_iso": iso8601(occurrence.start),
                "end_iso": iso8601(occurrence.end),
                "sheet_name": occurrence.sheetName,
                "cell_reference": occurrence.cellReference,
                "slot_label": occurrence.slotLabel
            ]
        }
        let initialData = try JSONSerialization.data(withJSONObject: initialOccurrences, options: [.sortedKeys, .prettyPrinted])
        let initialText = String(data: initialData, encoding: .utf8) ?? "[]"

        let instructions = verificationInstructions(for: imageExtractionStyle(for: configuration.provider))

        let prompt = """
        Verify and correct this schedule image extraction.

        Source name: \(source.name)
        Booking ID to match: \(source.bookingID)
        Calendar: \(source.calendar)
        Timezone: \(timeZone.identifier)
        Default workday: \(workdayHours.start)-\(workdayHours.end)

        First-pass candidate occurrences:
        \(initialText)
        \(ocrHints.map { "\nLocal OCR hints (secondary check only; trust the image if OCR conflicts):\n\($0)" } ?? "")
        """

        let payloadData = try await requestPayload(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: attachment
        )

        return try buildNormalizationResult(
            payloadData: payloadData,
            workbookFingerprint: workbookFingerprint,
            workdayHours: workdayHours,
            timeZone: timeZone
        )
    }

    private static func preferredImageNormalization(
        initial: AINormalizationResult,
        refined: AINormalizationResult
    ) -> AINormalizationResult {
        if refined.occurrences.isEmpty && !initial.occurrences.isEmpty {
            return initial
        }
        if refined.occurrences.count < initial.occurrences.count && !initial.occurrences.isEmpty {
            return initial
        }
        if refined.reviewRequired && !initial.reviewRequired {
            return initial
        }
        if initial.occurrences.count > 0 && abs(refined.occurrences.count - initial.occurrences.count) > max(4, initial.occurrences.count) {
            return initial
        }
        return refined
    }

    private static func applyImageProviderPolicy(
        to result: AINormalizationResult,
        provider: AIProvider
    ) -> AINormalizationResult {
        guard !result.occurrences.isEmpty else {
            return result
        }
        guard provider.requiresImageReviewByDefault else {
            return result
        }
        var adjusted = result
        adjusted.reviewRequired = true
        let policyNote: String
        switch provider {
        case .kimi:
            policyNote = "Kimi image parsing is still experimental. Review the extracted lessons before syncing."
        case .openAI, .anthropic, .openRouter, .custom:
            policyNote = "\(provider.title) image parsing should be reviewed before syncing. Gemini is currently the most reliable choice for uploaded timetable images."
        case .deepSeek:
            policyNote = "This AI platform does not support image parsing in the current app flow."
        case .gemini:
            policyNote = ""
        }
        if !policyNote.isEmpty, !adjusted.notes.contains(policyNote) {
            adjusted.notes.append(policyNote)
        }
        return adjusted
    }

    private static func imageExtractionStyle(for provider: AIProvider) -> ImageExtractionStyle {
        switch provider {
        case .gemini, .anthropic:
            return .directTimestamps
        case .openAI, .kimi, .openRouter, .custom, .deepSeek:
            return .visibleFields
        }
    }

    private static func imageSchema(for extractionStyle: ImageExtractionStyle) -> [String: Any] {
        switch extractionStyle {
        case .directTimestamps:
            return timestampNormalizationSchema()
        case .visibleFields:
            return imageNormalizationSchema()
        }
    }

    private static func imageInstructions(for extractionStyle: ImageExtractionStyle) -> String {
        switch extractionStyle {
        case .directTimestamps:
            return """
            You read schedule images and normalize them into atomic calendar occurrences.
            Match only reservations that belong to the provided booking ID.
            The image may show a month grid, table, or timetable. Read row labels, date labels, occupied slots, legends, color keys, teacher labels, and header annotations directly from the image.
            The booking ID may appear in a legend or teacher row rather than inside every occupied cell. Use that legend, subject label, teacher name, or color mapping to decide which occupied cells belong to the booking ID.
            If a legend maps the booking ID to a subject label, teacher label, or color, propagate that mapping to matching occupied cells across the schedule.
            If another legend clearly maps a different teacher or booking ID to other cells, exclude those cells.
            Legend cells, teacher labels, and header annotations are mapping hints only. Do not emit them as occurrences unless they are clearly inside the dated schedule grid and visibly represent an occupied lesson.
            Only emit occurrences for cells that are visibly occupied inside the actual timetable grid.
            Each occurrence must use the date from the same column directly above the occupied cell. Do not shift an occurrence to a neighboring day column.
            Respect weekly section boundaries when pairing a cell with its date header.
            Return one occurrence per directly observed occupied slot or day. Do not pre-merge adjacent matches.
            Use the supplied timezone for all timestamps.
            If the image gives a date without explicit times, use the provided default workday start and end for that day and set all_day to false.
            If the image gives explicit times or slot labels, use those times instead of the default workday.
            Do not invent bookings when the match is ambiguous. Return an empty occurrences array if nothing confidently matches.
            """
        case .visibleFields:
            return """
            You read schedule images and normalize them into atomic calendar occurrences.
            Match only reservations that belong to the provided booking ID.
            The image may show a month grid, table, or timetable. Read row labels, date labels, occupied slots, legends, color keys, teacher labels, and header annotations directly from the image.
            The booking ID may appear in a legend or teacher row rather than inside every occupied cell. Use that legend, subject label, teacher name, or color mapping to decide which occupied cells belong to the booking ID.
            If a legend maps the booking ID to a subject label, teacher label, or color, propagate that mapping to matching occupied cells across the schedule.
            If another legend clearly maps a different teacher or booking ID to other cells, exclude those cells.
            Legend cells, teacher labels, and header annotations are mapping hints only. Do not emit them as occurrences unless they are clearly inside the dated schedule grid and visibly represent an occupied lesson.
            Only emit occurrences for cells that are visibly occupied inside the actual timetable grid.
            Each occurrence must use the date text from the same column directly above the occupied cell. Copy that visible date text exactly into date_text. Do not shift an occurrence to a neighboring day column.
            Respect weekly section boundaries when pairing a cell with its date header.
            Return one occurrence per directly observed occupied slot or day. Do not pre-merge adjacent matches.
            Copy the visible time evidence instead of inventing normalized timestamps. Use time_text for the exact visible time string from the matched cell or, if the cell itself has no time, from the row label.
            Fill start_time_text and end_time_text with HH:mm values copied from the visible time range when possible.
            If the image gives a date without explicit times anywhere for that match, leave the time fields empty and set all_day to true so the app can fall back to the default workday locally.
            If the image gives explicit times or slot labels, use those visible times instead of the default workday.
            Use start_iso and end_iso only when a full unambiguous timestamp is explicitly visible in the image. Otherwise return empty strings for them.
            Do not invent bookings when the match is ambiguous. Return an empty occurrences array if nothing confidently matches.
            """
        }
    }

    private static func verificationInstructions(for extractionStyle: ImageExtractionStyle) -> String {
        switch extractionStyle {
        case .directTimestamps:
            return """
            You are verifying a first-pass extraction from a schedule image.
            Re-read the image carefully and correct the candidate occurrences if needed.
            Keep only lessons that directly belong to the provided booking ID.
            Remove legend cells, teacher labels, and headers. They are not events.
            Each lesson must use the date from the same column directly above the occupied cell.
            Respect weekly section boundaries and correct any shifted dates.
            Return corrected start_iso and end_iso values in the supplied timezone.
            Add any matching lessons that were missed in the first pass.
            Return valid JSON only.
            """
        case .visibleFields:
            return """
            You are verifying a first-pass extraction from a schedule image.
            Re-read the image carefully and correct the candidate occurrences if needed.
            Keep only lessons that directly belong to the provided booking ID.
            Remove legend cells, teacher labels, and headers. They are not events.
            Each lesson must use the date text from the same column directly above the occupied cell. Copy that date text exactly.
            Respect weekly section boundaries and correct any shifted dates.
            Copy visible time evidence into time_text, start_time_text, and end_time_text instead of inventing timestamps.
            Add any matching lessons that were missed in the first pass.
            Return valid JSON only.
            """
        }
    }

    private static func timestampNormalizationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "parser_summary": [
                    "type": "string"
                ],
                "occurrences": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "sheet_name": ["type": "string"],
                            "cell_reference": ["type": "string"],
                            "start_iso": ["type": "string"],
                            "end_iso": ["type": "string"],
                            "all_day": ["type": "boolean"],
                            "confidence": ["type": "number"],
                            "explanation": ["type": "string"]
                        ],
                        "required": [
                            "sheet_name",
                            "cell_reference",
                            "start_iso",
                            "end_iso",
                            "all_day",
                            "confidence",
                            "explanation"
                        ]
                    ]
                ]
            ],
            "required": ["parser_summary", "occurrences"]
        ]
    }

    private static func parseNormalizationPayload(_ payloadData: Data) throws -> AINormalizationPayload {
        let raw = try JSONSerialization.jsonObject(with: payloadData)
        guard let dictionary = raw as? [String: Any] else {
            throw AppFailure.invalidAIResponse("The AI response was not a JSON object.")
        }

        let parserSummary = stringValue(
            in: dictionary,
            keys: ["parser_summary", "parserSummary", "summary", "parser", "note", "notes"]
        ) ?? "AI normalized this source."

        let occurrenceCandidates = [
            dictionary["occurrences"],
            dictionary["matches"],
            dictionary["reservations"],
            dictionary["events"],
            dictionary["bookings"]
        ]
        guard let rawOccurrences = occurrenceCandidates.compactMap({ $0 as? [[String: Any]] }).first else {
            let keys = dictionary.keys.sorted().joined(separator: ", ")
            throw AppFailure.invalidAIResponse("The AI response did not include an occurrences array. Top-level keys: \(keys)")
        }

        let occurrences = rawOccurrences.compactMap { item -> AINormalizedOccurrence? in
            guard
                let sheetName = stringValue(in: item, keys: ["sheet_name", "sheetName", "sheet", "worksheet", "tab"]),
                let cellReference = stringValue(in: item, keys: ["cell_reference", "cellReference", "cell", "range"])
            else {
                return nil
            }

            let startISO = stringValue(in: item, keys: ["start_iso", "startISO", "start"])
            let endISO = stringValue(in: item, keys: ["end_iso", "endISO", "end"])
            let dateText = stringValue(in: item, keys: ["date_text", "dateText", "date", "header_date", "headerDate"])
            let timeText = stringValue(in: item, keys: ["time_text", "timeText", "visible_time", "visibleTime", "row_label", "rowLabel"])
            let startTimeText = stringValue(in: item, keys: ["start_time_text", "startTimeText", "start_time", "startTime"])
            let endTimeText = stringValue(in: item, keys: ["end_time_text", "endTimeText", "end_time", "endTime"])
            let lessonText = stringValue(in: item, keys: ["lesson_text", "lessonText", "cell_text", "cellText", "content"])
            let allDay = boolValue(in: item, keys: ["all_day", "allDay", "isAllDay"]) ?? false

            let hasISODateTime = startISO != nil && endISO != nil
            let hasVisibleDateTime = dateText != nil && (
                allDay ||
                (startTimeText != nil && endTimeText != nil) ||
                parseVisibleTimeRange(
                    startTimeText: startTimeText,
                    endTimeText: endTimeText,
                    fallbackText: [timeText, lessonText].compactMap { $0 }.joined(separator: " ")
                ) != nil
            )
            guard hasISODateTime || hasVisibleDateTime else {
                return nil
            }

            return AINormalizedOccurrence(
                sheetName: sheetName,
                cellReference: cellReference,
                startISO: startISO,
                endISO: endISO,
                dateText: dateText,
                timeText: timeText,
                startTimeText: startTimeText,
                endTimeText: endTimeText,
                lessonText: lessonText,
                allDay: allDay,
                confidence: doubleValue(in: item, keys: ["confidence", "score"]) ?? 0.75,
                explanation: stringValue(in: item, keys: ["explanation", "reason", "note"]) ?? "AI normalized this booking."
            )
        }

        return AINormalizationPayload(parserSummary: parserSummary, occurrences: occurrences)
    }

    private static func requestPayload(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment? = nil
    ) async throws -> Data {
        let requestConfiguration = configuration.configurationForRequest(isImageParsing: imageAttachment != nil)
        let payloadText: String
        switch requestConfiguration.requestStyle {
        case .responses:
            payloadText = try await requestResponsesPayloadText(
                configuration: requestConfiguration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
        case .chatCompletions:
            payloadText = try await requestChatCompletionsPayloadText(
                configuration: requestConfiguration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
        case .anthropicMessages:
            payloadText = try await requestAnthropicPayloadText(
                configuration: requestConfiguration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
        case .geminiGenerateContent:
            payloadText = try await requestGeminiPayloadText(
                configuration: requestConfiguration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
        }

        return Data(payloadText.utf8)
    }

    private static func requestResponsesPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        let input: Any
        if let imageAttachment {
            input = [[
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": prompt
                    ],
                    [
                        "type": "input_image",
                        "image_url": dataURL(for: imageAttachment)
                    ]
                ]
            ]]
        } else {
            input = prompt
        }

        var body: [String: Any] = [
            "model": configuration.model,
            "instructions": instructions,
            "input": input,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "reservation_occurrences",
                    "schema": schema,
                    "strict": true
                ]
            ]
        ]
        if configuration.provider == .openAI {
            body["reasoning"] = [
                "effort": imageAttachment == nil ? "medium" : "low"
            ]
        }

        let data = try await performAIRequest(configuration: configuration, body: body)
        let envelope = try JSONDecoder().decode(ResponsesAPIEnvelope.self, from: data)
        guard let payloadText = extractResponsesPayloadText(from: envelope) else {
            throw AppFailure.invalidAIResponse("The AI response did not include structured text.")
        }
        return payloadText
    }

    private static func requestChatCompletionsPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        try await requestChatCompletionsPayloadText(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: imageAttachment,
            allowRetry: true
        )
    }

    private static func requestChatCompletionsPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?,
        allowRetry: Bool
    ) async throws -> String {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard let schemaText = String(data: schemaData, encoding: .utf8) else {
            throw AppFailure.invalidAIResponse("Could not encode the AI schema.")
        }

        let systemPrompt: String
        if configuration.provider == .kimi {
            systemPrompt = """
            \(instructions)
            Return valid JSON only. Do not wrap the answer in markdown.
            Do not return schema definitions such as type, properties, required, or additionalProperties.
            \(kimiSchemaGuidance(for: schema))
            """
        } else {
            systemPrompt = """
            \(instructions)
            Return valid JSON only. Do not wrap the answer in markdown.
            The JSON must match this schema exactly:
            \(schemaText)
            """
        }

        let userContent: Any
        if let imageAttachment {
            userContent = [
                [
                    "type": "text",
                    "text": prompt
                ],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": dataURL(for: imageAttachment)
                    ]
                ]
            ]
        } else {
            userContent = prompt
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userContent
                ]
            ],
            "response_format": [
                "type": "json_object"
            ],
            "temperature": 0
        ]

        let data = try await performAIRequest(configuration: configuration, body: body)
        let envelope = try JSONDecoder().decode(ChatCompletionsEnvelope.self, from: data)
        guard let content = envelope.choices.first?.message.content else {
            throw AppFailure.invalidAIResponse("The AI response did not include a completion message.")
        }
        if let payloadText = extractJSONText(from: content) {
            return payloadText
        }
        if configuration.provider == .kimi,
           let repaired = try await repairChatCompletionsJSON(
            configuration: configuration,
            schema: schema,
            rawContent: content
           ) {
            return repaired
        }
        guard allowRetry else {
            throw AppFailure.invalidAIResponse("The AI response did not return valid JSON text.")
        }
        let retryInstructions = instructions + "\nYour previous answer was not valid JSON. Return only one compact JSON object and nothing else."
        return try await requestChatCompletionsPayloadText(
            configuration: configuration,
            instructions: retryInstructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: imageAttachment,
            allowRetry: false
        )
    }

    private static func repairChatCompletionsJSON(
        configuration: AIServiceConfiguration,
        schema: [String: Any],
        rawContent: String
    ) async throws -> String? {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard let schemaText = String(data: schemaData, encoding: .utf8) else {
            return nil
        }
        var repairConfiguration = configuration
        if configuration.provider == .kimi {
            repairConfiguration.model = configuration.provider.automaticSheetModel
        }

        let body: [String: Any] = [
            "model": repairConfiguration.model,
            "messages": [
                [
                    "role": "system",
                    "content": configuration.provider == .kimi
                        ? """
                        Convert the assistant answer into one compact JSON object.
                        Keep only facts already present in the answer.
                        Do not add commentary or markdown.
                        Do not return schema definitions such as type, properties, required, or additionalProperties.
                        \(kimiSchemaGuidance(for: schema))
                        """
                        : """
                        Convert the assistant answer into one compact JSON object.
                        Keep only facts already present in the answer.
                        Do not add commentary or markdown.
                        The JSON must match this schema exactly:
                        \(schemaText)
                        """
                ],
                [
                    "role": "user",
                    "content": "Repair this answer into valid JSON only:\n\(rawContent)"
                ]
            ],
            "response_format": [
                "type": "json_object"
            ],
            "temperature": 0
        ]

        let data = try await performAIRequest(configuration: repairConfiguration, body: body)
        let envelope = try JSONDecoder().decode(ChatCompletionsEnvelope.self, from: data)
        guard let content = envelope.choices.first?.message.content else {
            return nil
        }
        return extractJSONText(from: content)
    }

    private static func requestAnthropicPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        try await requestAnthropicPayloadText(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: imageAttachment,
            allowRetry: true
        )
    }

    private static func requestAnthropicPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?,
        allowRetry: Bool
    ) async throws -> String {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard let schemaText = String(data: schemaData, encoding: .utf8) else {
            throw AppFailure.invalidAIResponse("Could not encode the AI schema.")
        }

        let systemPrompt = """
        \(instructions)
        Return valid JSON only. Do not wrap the answer in markdown.
        The JSON must match this schema exactly:
        \(schemaText)
        """

        var userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt
            ]
        ]
        if let imageAttachment {
            userContent.insert([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": imageAttachment.mimeType,
                    "data": imageAttachment.data.base64EncodedString()
                ]
            ], at: 0)
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": userContent
                ]
            ]
        ]

        let data = try await performAnthropicRequest(configuration: configuration, body: body)
        let envelope = try JSONDecoder().decode(AnthropicMessagesEnvelope.self, from: data)
        let content = envelope.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
        if let payloadText = extractJSONText(from: content) {
            return payloadText
        }
        guard allowRetry else {
            throw AppFailure.invalidAIResponse("The Anthropic response did not return valid JSON text.")
        }
        let retryInstructions = instructions + "\nYour previous answer was not valid JSON. Return only one compact JSON object and nothing else."
        return try await requestAnthropicPayloadText(
            configuration: configuration,
            instructions: retryInstructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: imageAttachment,
            allowRetry: false
        )
    }

    private static func requestGeminiPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard let schemaText = String(data: schemaData, encoding: .utf8) else {
            throw AppFailure.invalidAIResponse("Could not encode the AI schema.")
        }

        let fullPrompt = """
        \(instructions)
        Return valid JSON only. Do not wrap the answer in markdown.
        The JSON must match this schema exactly:
        \(schemaText)

        \(prompt)
        """

        var parts: [[String: Any]] = [
            [
                "text": fullPrompt
            ]
        ]
        if let imageAttachment {
            parts.append([
                "inlineData": [
                    "mimeType": imageAttachment.mimeType,
                    "data": imageAttachment.data.base64EncodedString()
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json"
            ]
        ]

        let data = try await performGeminiRequest(configuration: configuration, body: body)
        let envelope = try JSONDecoder().decode(GeminiGenerateContentEnvelope.self, from: data)
        let content = envelope.candidates?
            .compactMap { $0.content?.parts?.compactMap(\.text).joined(separator: "\n") }
            .first ?? ""
        guard let payloadText = extractJSONText(from: content) else {
            throw AppFailure.invalidAIResponse("The Gemini response did not return valid JSON text.")
        }
        return payloadText
    }

    private static func performAIRequest(
        configuration: AIServiceConfiguration,
        body: [String: Any]
    ) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 90

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 90
        sessionConfiguration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: sessionConfiguration)
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw AppFailure.syncFailed("AI parser request failed with HTTP \(httpResponse.statusCode): \(message)")
        }
        return data
    }

    private static func performAnthropicRequest(
        configuration: AIServiceConfiguration,
        body: [String: Any]
    ) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 90

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 90
        sessionConfiguration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: sessionConfiguration)
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw AppFailure.syncFailed("AI parser request failed with HTTP \(httpResponse.statusCode): \(message)")
        }
        return data
    }

    private static func performGeminiRequest(
        configuration: AIServiceConfiguration,
        body: [String: Any]
    ) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: geminiRequestURL(for: configuration))
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 90

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 90
        sessionConfiguration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: sessionConfiguration)
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw AppFailure.syncFailed("AI parser request failed with HTTP \(httpResponse.statusCode): \(message)")
        }
        return data
    }

    private static func geminiRequestURL(for configuration: AIServiceConfiguration) -> URL {
        let endpoint = configuration.endpointURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.contains(":generateContent"), let url = URL(string: endpoint) {
            return url
        }
        let trimmed = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return URL(string: "\(trimmed)/\(configuration.model):generateContent")!
    }

    private static func snapshotSheet(_ sheet: ParsedWorkbookSheet) -> WorkbookSnapshotSheet {
        let rows = (1...sheet.worksheet.maxRow).compactMap { row -> WorkbookSnapshotRow? in
            guard let rowCells = sheet.worksheet.cellsByRow[row], !rowCells.isEmpty else { return nil }
            let cells = rowCells.keys.sorted().compactMap { column -> WorkbookSnapshotCell? in
                guard let rawValue = rowCells[column] else { return nil }
                let value = rawValue
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return WorkbookSnapshotCell(column: columnLetters(column), value: value)
            }
            guard !cells.isEmpty else { return nil }
            return WorkbookSnapshotRow(rowNumber: row, cells: cells)
        }
        return WorkbookSnapshotSheet(name: sheet.name, rows: rows)
    }

    private static func extractResponsesPayloadText(from envelope: ResponsesAPIEnvelope) -> String? {
        if let outputText = envelope.outputText, !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        for item in envelope.output ?? [] {
            for content in item.content ?? [] {
                if let text = content.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func kimiSchemaGuidance(for schema: [String: Any]) -> String {
        if isVisibleFieldSchema(schema) {
            return """
            Return exactly one object with these top-level keys:
            - parser_summary: string
            - occurrences: array
            Each occurrence object must include:
            - sheet_name: string
            - cell_reference: string
            - date_text: string
            - time_text: string
            - start_time_text: string
            - end_time_text: string
            - lesson_text: string
            - start_iso: string (empty string if unavailable)
            - end_iso: string (empty string if unavailable)
            - all_day: boolean
            - confidence: number
            - explanation: string
            """
        }
        return """
        Return exactly one object with these top-level keys:
        - parser_summary: string
        - occurrences: array
        Each occurrence object must include:
        - sheet_name: string
        - cell_reference: string
        - start_iso: string
        - end_iso: string
        - all_day: boolean
        - confidence: number
        - explanation: string
        """
    }

    private static func isVisibleFieldSchema(_ schema: [String: Any]) -> Bool {
        guard
            let properties = schema["properties"] as? [String: Any],
            let occurrences = properties["occurrences"] as? [String: Any],
            let items = occurrences["items"] as? [String: Any],
            let itemProperties = items["properties"] as? [String: Any]
        else {
            return false
        }
        return itemProperties["date_text"] != nil
    }

    private static func extractJSONText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isJSONObject(trimmed) {
            return trimmed
        }

        if trimmed.hasPrefix("```"), let fenced = extractFencedJSON(from: trimmed), isJSONObject(fenced) {
            return fenced
        }

        if let firstBrace = trimmed.firstIndex(of: "{"), let lastBrace = trimmed.lastIndex(of: "}") {
            let candidate = String(trimmed[firstBrace...lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isJSONObject(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func extractFencedJSON(from text: String) -> String? {
        let components = text.components(separatedBy: "```")
        guard components.count >= 3 else { return nil }
        let candidate = components[1]
            .replacingOccurrences(of: "json", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private static func isJSONObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func chronologicalAnomalyNote(for occurrences: [SlotOccurrence]) -> String? {
        guard !occurrences.isEmpty else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let years = occurrences.compactMap { calendar.dateComponents([.year], from: $0.start).year }.sorted()
        let currentYear = calendar.component(.year, from: Date())
        if let nearestYear = years.min(by: { abs($0 - currentYear) < abs($1 - currentYear) }),
           abs(nearestYear - currentYear) > 1 {
            return "AI returned dates more than one year away from the current year. Review is required before syncing."
        }
        if let firstYear = years.first, let lastYear = years.last, lastYear - firstYear > 1 {
            return "AI returned dates that jump across non-adjacent years. Review is required before syncing."
        }
        let starts = occurrences.map(\.start).sorted()
        if let first = starts.first, let last = starts.last,
           last.timeIntervalSince(first) > 370 * 24 * 60 * 60 {
            return "AI returned events spread across an unusually long time range. Review is required before syncing."
        }
        return nil
    }

    private static func dataURL(for imageAttachment: AIImageAttachment) -> String {
        "data:\(imageAttachment.mimeType);base64,\(imageAttachment.data.base64EncodedString())"
    }

    private static func makeImageAttachment(from imageURL: URL) throws -> AIImageAttachment? {
        guard let mimeType = imageMimeType(for: imageURL) else {
            return nil
        }
        let data = try Data(contentsOf: imageURL)
        return AIImageAttachment(data: data, mimeType: mimeType)
    }
}

private struct ReservationExtractor {
    static func extract(
        source: SourceItem,
        workdayHours: WorkdayHours,
        upcomingOnly: Bool,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?
    ) async throws -> ExtractionResult {
        if let imageURL = localImageURL(from: source.source) {
            return try await extractImageSource(
                source: source,
                workdayHours: workdayHours,
                upcomingOnly: upcomingOnly,
                parserMode: parserMode,
                aiConfiguration: aiConfiguration,
                imageURL: imageURL
            )
        }

        let workbookURL = try await downloadWorkbook(from: source.source)
        let isTemporary = !FileManager.default.fileExists(atPath: source.source)
        let package = try XLSXPackage(xlsxURL: workbookURL)
        defer {
            package.cleanup()
            if isTemporary {
                try? FileManager.default.removeItem(at: workbookURL)
            }
        }

        let workbookData = try package.data(at: "xl/workbook.xml")
        let relsData = try package.data(at: "xl/_rels/workbook.xml.rels")
        let sharedStringsData = (try? package.data(at: "xl/sharedStrings.xml")) ?? Data()

        let workbookSheets = WorkbookParser().parse(data: workbookData)
        let relationships = RelationshipParser().parse(data: relsData)
        let sharedStrings = SharedStringsParser().parse(data: sharedStringsData)

        let timeZone = TimeZone(identifier: "Asia/Singapore") ?? .current
        let calendar = Calendar(identifier: .gregorian)

        var parsedSheets: [ParsedWorkbookSheet] = []
        for sheet in workbookSheets {
            guard let target = relationships[sheet.relationshipID] else { continue }
            let sheetData = try package.data(at: normalizeWorkbookPath(target))
            let worksheet = WorksheetParser(sharedStrings: sharedStrings).parse(data: sheetData)
            if worksheet.maxRow == 0 { continue }
            let parsedMonth = parseMonthSheet(sheet.name)
            parsedSheets.append(
                ParsedWorkbookSheet(
                    name: sheet.name,
                    year: parsedMonth?.0,
                    month: parsedMonth?.1,
                    worksheet: worksheet
                )
            )
        }

        let ruleOccurrences = try extractRuleOccurrences(
            source: source,
            workdayHours: workdayHours,
            sheets: parsedSheets,
            calendar: calendar,
            timeZone: timeZone
        )

        let parserSelection = try await chooseOccurrences(
            source: source,
            workdayHours: workdayHours,
            parserMode: parserMode,
            aiConfiguration: aiConfiguration,
            parsedSheets: parsedSheets,
            ruleOccurrences: ruleOccurrences,
            timeZone: timeZone
        )

        var occurrences = parserSelection.occurrences
        let parserLabel = parserSelection.label
        let parserNotes = parserSelection.notes

        occurrences.sort { $0.start < $1.start }
        let allEvents = mergeReservationOccurrences(occurrences: occurrences, source: source)
        let filteredEvents: [ReservationEvent]
        if upcomingOnly {
            filteredEvents = futureOnlyEvents(from: allEvents, timeZone: timeZone)
        } else {
            filteredEvents = allEvents
        }
        return ExtractionResult(
            allEvents: allEvents,
            filteredEvents: filteredEvents,
            filteredPastCount: max(allEvents.count - filteredEvents.count, 0),
            parserLabel: parserLabel,
            parserNotes: parserNotes,
            reviewRequired: parserSelection.reviewRequired,
            workbookFingerprint: parserSelection.workbookFingerprint,
            averageConfidence: parserSelection.averageConfidence,
            minimumConfidence: parserSelection.minimumConfidence
        )
    }

    private static func extractImageSource(
        source: SourceItem,
        workdayHours: WorkdayHours,
        upcomingOnly: Bool,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        imageURL: URL
    ) async throws -> ExtractionResult {
        let timeZone = TimeZone(identifier: "Asia/Singapore") ?? .current
        if let localResult = try LocalTimetableImageParser.parse(
            source: source,
            workdayHours: workdayHours,
            imageURL: imageURL,
            timeZone: timeZone
        ) {
            let occurrences = localResult.occurrences.sorted { $0.start < $1.start }
            let allEvents = mergeReservationOccurrences(occurrences: occurrences, source: source)
            let filteredEvents: [ReservationEvent]
            if upcomingOnly {
                filteredEvents = futureOnlyEvents(from: allEvents, timeZone: timeZone)
            } else {
                filteredEvents = allEvents
            }

            return ExtractionResult(
                allEvents: allEvents,
                filteredEvents: filteredEvents,
                filteredPastCount: max(allEvents.count - filteredEvents.count, 0),
                parserLabel: "Local timetable image",
                parserNotes: localResult.notes,
                reviewRequired: false,
                workbookFingerprint: nil,
                averageConfidence: nil,
                minimumConfidence: nil
            )
        }

        guard parserMode != .rulesOnly else {
            throw AppFailure.invalidAIConfiguration("Image schedules require AI parsing. Change Parser Mode to Auto or AI.")
        }
        guard let aiConfiguration else {
            throw AppFailure.invalidAIConfiguration("Set an AI platform and API key before using an image source.")
        }
        guard aiConfiguration.provider.supportsImageParsing else {
            throw AppFailure.invalidAIConfiguration("The selected AI platform does not support image parsing yet. Use a platform marked '(images)' for image sources.")
        }
        let normalized = try await AIWorkbookNormalizer.normalizeImage(
            source: source,
            workdayHours: workdayHours,
            imageURL: imageURL,
            configuration: aiConfiguration,
            timeZone: timeZone
        )
        let occurrences = normalized.occurrences.sorted { $0.start < $1.start }
        let allEvents = mergeReservationOccurrences(occurrences: occurrences, source: source)
        let filteredEvents: [ReservationEvent]
        if upcomingOnly {
            filteredEvents = futureOnlyEvents(from: allEvents, timeZone: timeZone)
        } else {
            filteredEvents = allEvents
        }

        return ExtractionResult(
            allEvents: allEvents,
            filteredEvents: filteredEvents,
            filteredPastCount: max(allEvents.count - filteredEvents.count, 0),
            parserLabel: "AI image parsing",
            parserNotes: normalized.notes,
            reviewRequired: normalized.reviewRequired,
            workbookFingerprint: normalized.workbookFingerprint,
            averageConfidence: normalized.averageConfidence,
            minimumConfidence: normalized.minimumConfidence
        )
    }

    private static func chooseOccurrences(
        source: SourceItem,
        workdayHours: WorkdayHours,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        parsedSheets: [ParsedWorkbookSheet],
        ruleOccurrences: [SlotOccurrence],
        timeZone: TimeZone
    ) async throws -> ParserSelection {
        switch parserMode {
        case .rulesOnly:
            return ParserSelection(
                occurrences: ruleOccurrences,
                label: "Rule-based",
                notes: ["Used local slot and occupancy rules only."],
                reviewRequired: false,
                workbookFingerprint: nil,
                averageConfidence: nil,
                minimumConfidence: nil
            )
        case .auto:
            if !ruleOccurrences.isEmpty {
                return ParserSelection(
                    occurrences: ruleOccurrences,
                    label: "Rule-based",
                    notes: ["Built-in workbook rules matched this source, so AI fallback was not needed."],
                    reviewRequired: false,
                    workbookFingerprint: nil,
                    averageConfidence: nil,
                    minimumConfidence: nil
                )
            }
            guard let aiConfiguration else {
                return ParserSelection(
                    occurrences: ruleOccurrences,
                    label: "Rule-based",
                    notes: ["AI fallback is not configured, so only local rules were used."],
                    reviewRequired: false,
                    workbookFingerprint: nil,
                    averageConfidence: nil,
                    minimumConfidence: nil
                )
            }
            let normalized = try await AIWorkbookNormalizer.normalize(
                source: source,
                workdayHours: workdayHours,
                sheets: parsedSheets,
                configuration: aiConfiguration,
                timeZone: timeZone
            )
            return ParserSelection(
                occurrences: normalized.occurrences,
                label: "AI normalization",
                notes: normalized.notes,
                reviewRequired: normalized.reviewRequired,
                workbookFingerprint: normalized.workbookFingerprint,
                averageConfidence: normalized.averageConfidence,
                minimumConfidence: normalized.minimumConfidence
            )
        case .aiOnly:
            guard let aiConfiguration else {
                throw AppFailure.invalidAIConfiguration("Set an endpoint URL, model, and API key before using AI mode.")
            }
            let normalized = try await AIWorkbookNormalizer.normalize(
                source: source,
                workdayHours: workdayHours,
                sheets: parsedSheets,
                configuration: aiConfiguration,
                timeZone: timeZone
            )
            return ParserSelection(
                occurrences: normalized.occurrences,
                label: "AI normalization",
                notes: normalized.notes,
                reviewRequired: normalized.reviewRequired,
                workbookFingerprint: normalized.workbookFingerprint,
                averageConfidence: normalized.averageConfidence,
                minimumConfidence: normalized.minimumConfidence
            )
        }
    }

    private static func extractRuleOccurrences(
        source: SourceItem,
        workdayHours: WorkdayHours,
        sheets: [ParsedWorkbookSheet],
        calendar: Calendar,
        timeZone: TimeZone
    ) throws -> [SlotOccurrence] {
        var occurrences: [SlotOccurrence] = []
        for sheet in sheets {
            guard let year = sheet.year, let month = sheet.month else { continue }
            occurrences += try extractSheetOccurrences(
                worksheet: sheet.worksheet,
                source: source,
                sheetName: sheet.name,
                year: year,
                month: month,
                calendar: calendar,
                timeZone: timeZone,
                workdayHours: workdayHours
            )
        }
        return occurrences
    }

    private static func extractSheetOccurrences(
        worksheet: WorksheetParser,
        source: SourceItem,
        sheetName: String,
        year: Int,
        month: Int,
        calendar: Calendar,
        timeZone: TimeZone,
        workdayHours: WorkdayHours
    ) throws -> [SlotOccurrence] {
        var occurrences: [SlotOccurrence] = []

        for row in 1...worksheet.maxRow {
            var dayColumns: [Int: Int] = [:]
            for column in 1...worksheet.maxColumn {
                if let text = worksheet.cellsByRow[row]?[column], let day = dayNumber(from: text) {
                    dayColumns[column] = day
                }
            }
            if dayColumns.isEmpty { continue }

            let slotRows = matchingSlotRows(for: row, worksheet: worksheet)
            if !slotRows.isEmpty {
                occurrences += try extractPPMSSlotOccurrences(
                    sheetName: sheetName,
                    source: source,
                    dayColumns: dayColumns,
                    slotRows: slotRows,
                    year: year,
                    month: month,
                    calendar: calendar,
                    timeZone: timeZone,
                    worksheet: worksheet
                )
                continue
            }

            occurrences += extractDailyOccupancyOccurrences(
                workdayHours: workdayHours,
                sheetName: sheetName,
                source: source,
                dayColumns: dayColumns,
                dayRow: row,
                year: year,
                month: month,
                calendar: calendar,
                timeZone: timeZone,
                worksheet: worksheet
            )
        }

        return occurrences
    }

    private static func matchingSlotRows(
        for row: Int,
        worksheet: WorksheetParser
    ) -> [(SlotRule, Int)] {
        var slotRows: [(SlotRule, Int)] = []
        for offset in 1...6 {
            let label = worksheet.cellsByRow[row + offset]?[1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let rule = inferredSlotRule(from: label) {
                slotRows.append((rule, row + offset))
                continue
            }
            if !slotRows.isEmpty {
                break
            }
        }
        return slotRows
    }

    private static func extractPPMSSlotOccurrences(
        sheetName: String,
        source: SourceItem,
        dayColumns: [Int: Int],
        slotRows: [(SlotRule, Int)],
        year: Int,
        month: Int,
        calendar: Calendar,
        timeZone: TimeZone,
        worksheet: WorksheetParser
    ) throws -> [SlotOccurrence] {
        var occurrences: [SlotOccurrence] = []

        for (column, day) in dayColumns {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.timeZone = timeZone
            guard let baseDate = calendar.date(from: components) else { continue }

            for (rule, slotRow) in slotRows {
                guard let value = worksheet.cellsByRow[slotRow]?[column],
                      value.caseInsensitiveCompare(source.bookingID) == .orderedSame else { continue }
                let start = try buildDate(from: baseDate, timeString: rule.start, in: timeZone)
                var end = try buildDate(from: baseDate, timeString: rule.end, in: timeZone)
                if rule.endsNextDay {
                    end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
                }
                let reference = "\(columnLetters(column))\(slotRow)"
                occurrences.append(
                    SlotOccurrence(
                        start: start,
                        end: end,
                        sheetName: sheetName,
                        cellReference: reference,
                        slotLabel: rule.sheetLabel,
                        isAllDay: false
                    )
                )
            }
        }

        return occurrences
    }

    private static func extractDailyOccupancyOccurrences(
        workdayHours: WorkdayHours,
        sheetName: String,
        source: SourceItem,
        dayColumns: [Int: Int],
        dayRow: Int,
        year: Int,
        month: Int,
        calendar: Calendar,
        timeZone: TimeZone,
        worksheet: WorksheetParser
    ) -> [SlotOccurrence] {
        let occupancyRow = dayRow + 1
        let leadingLabel = worksheet.cellsByRow[occupancyRow]?[1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if inferredSlotRule(from: leadingLabel) != nil {
            return []
        }

        let occupiedColumnCount = dayColumns.keys.reduce(into: 0) { count, column in
            if let value = worksheet.cellsByRow[occupancyRow]?[column],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        guard occupiedColumnCount > 0 else { return [] }

        var occurrences: [SlotOccurrence] = []
        for (column, day) in dayColumns {
            guard let value = worksheet.cellsByRow[occupancyRow]?[column],
                  value.caseInsensitiveCompare(source.bookingID) == .orderedSame else { continue }

            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.timeZone = timeZone
            guard let baseDate = calendar.date(from: components),
                  let range = buildWorkdayRange(
                    on: baseDate,
                    workdayHours: workdayHours,
                    calendar: calendar,
                    timeZone: timeZone
                  ) else { continue }

            let reference = "\(columnLetters(column))\(occupancyRow)"
            occurrences.append(
                SlotOccurrence(
                    start: range.0,
                    end: range.1,
                    sheetName: sheetName,
                    cellReference: reference,
                    slotLabel: "default-workday",
                    isAllDay: false
                )
            )
        }

        return occurrences
    }

    private static func inferredSlotRule(from label: String) -> SlotRule? {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        if let builtin = builtinSlotRules().first(where: {
            $0.sheetLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }) {
            return builtin
        }

        guard let range = parseSlotRange(from: normalized) else {
            return nil
        }
        return SlotRule(
            sheetLabel: label,
            start: range.start,
            end: range.end,
            endsNextDay: range.endsNextDay
        )
    }

    private static func parseSlotRange(from label: String) -> (start: String, end: String, endsNextDay: Bool)? {
        let normalized = label
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
            .replacingOccurrences(of: " ", with: "")
        let parts = normalized.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let startCandidates = resolvedTimeCandidates(from: parts[0]),
              let endCandidates = resolvedTimeCandidates(from: parts[1]) else {
            return nil
        }

        let best = startCandidates.flatMap { start in
            endCandidates.map { end -> (start: Int, end: Int, duration: Int) in
                let duration = end > start ? end - start : (24 * 60 - start) + end
                return (start: start, end: end, duration: duration)
            }
        }
        .filter { $0.duration > 0 }
        .sorted {
            if ($0.duration <= 16 * 60) != ($1.duration <= 16 * 60) {
                return $0.duration <= 16 * 60
            }
            return $0.duration < $1.duration
        }
        .first

        guard let best else { return nil }
        return (
            start: clockString(fromMinutes: best.start),
            end: clockString(fromMinutes: best.end),
            endsNextDay: best.end <= best.start
        )
    }

    private static func resolvedTimeCandidates(from token: String) -> [Int]? {
        let pattern = #"^(\d{1,2})(?::(\d{2}))?([ap]m)?$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
              let hourRange = Range(match.range(at: 1), in: token) else {
            return nil
        }
        let minuteRange = Range(match.range(at: 2), in: token)
        let meridiemRange = Range(match.range(at: 3), in: token)

        guard let hour = Int(token[hourRange]) else { return nil }
        let minute = minuteRange.flatMap { Int(token[$0]) } ?? 0
        guard (0...59).contains(minute) else { return nil }

        if let meridiemRange {
            let meridiem = token[meridiemRange]
            guard (1...12).contains(hour) else { return nil }
            let normalizedHour: Int
            if meridiem == "am" {
                normalizedHour = hour == 12 ? 0 : hour
            } else {
                normalizedHour = hour == 12 ? 12 : hour + 12
            }
            return [normalizedHour * 60 + minute]
        }

        guard (0...23).contains(hour) else { return nil }
        if hour == 0 || hour >= 13 {
            return [hour * 60 + minute]
        }
        return [hour * 60 + minute, (hour + 12) * 60 + minute]
    }

    private static func mergeOccurrences(occurrences: [SlotOccurrence], source: SourceItem) -> [ReservationEvent] {
        mergeReservationOccurrences(occurrences: occurrences, source: source)
    }
}

private func sourceIdentity(for source: SourceItem) -> String {
    digest("\(source.name)|\(source.source)|\(source.bookingID)|\(source.calendar)")
}

private func mergeReservationOccurrences(occurrences: [SlotOccurrence], source: SourceItem) -> [ReservationEvent] {
    let sourceID = sourceIdentity(for: source)
    var merged: [ReservationEvent] = []

    for occurrence in occurrences {
        if var current = merged.last, occurrence.isAllDay == current.isAllDay, occurrence.start <= current.end {
            current.end = max(current.end, occurrence.end)
            current.sheetNames.append(occurrence.sheetName)
            current.cellReferences.append(occurrence.cellReference)
            current.syncKey = digest("\(sourceID)|\(current.sheetNames.joined(separator: ","))|\(current.cellReferences.joined(separator: ","))|\(source.bookingID)")
            merged[merged.count - 1] = current
        } else {
            let syncKey = digest("\(sourceID)|\(occurrence.sheetName)|\(occurrence.cellReference)|\(source.bookingID)")
            merged.append(
                ReservationEvent(
                    syncKey: syncKey,
                    sourceID: sourceID,
                    sourceName: source.name,
                    sourceLink: source.source,
                    bookingID: source.bookingID,
                    calendarName: source.calendar,
                    start: occurrence.start,
                    end: occurrence.end,
                    isAllDay: occurrence.isAllDay,
                    sheetNames: [occurrence.sheetName],
                    cellReferences: [occurrence.cellReference]
                )
            )
        }
    }

    return merged
}

private func futureOnlyEvents(
    from events: [ReservationEvent],
    timeZone: TimeZone
) -> [ReservationEvent] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let now = Date()
    guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
        return events.filter { $0.start > now }
    }
    return events.filter { $0.start >= startOfTomorrow }
}

private actor CalendarSyncEngine {
    private let store = EKEventStore()

    func calendarAccessState() -> CalendarAccessState {
        currentCalendarAccessState()
    }

    func calendarNamesIfAuthorized() -> [String]? {
        guard currentCalendarAccessState().hasUsableAccess else {
            return nil
        }
        return store.calendars(for: .event)
            .map(\.title)
            .sorted()
    }

    func requestCalendarAccess() async throws {
        try await ensureAccess()
    }

    func calendarNames() async throws -> [String] {
        try await ensureAccess()
        return store.calendars(for: .event)
            .map(\.title)
            .sorted()
    }

    func sync(
        sources: [SourceItem],
        workdayHours: WorkdayHours,
        upcomingOnly: Bool,
        previewOnly: Bool,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        aiApprovals: [AIApprovalRecord]
    ) async throws -> SyncRunResult {
        try await ensureAccess()
        var state = SettingsStore.loadState()
        var reports: [SourceSyncReport] = []
        var lines: [String] = []

        for source in sources where source.enabled {
            do {
                let extraction = try await ReservationExtractor.extract(
                    source: source,
                    workdayHours: workdayHours,
                    upcomingOnly: upcomingOnly,
                    parserMode: parserMode,
                    aiConfiguration: aiConfiguration
                )
                let report = try syncSource(
                    source: source,
                    extraction: extraction,
                    state: &state,
                    previewOnly: previewOnly,
                    aiApprovals: aiApprovals
                )
                reports.append(report)

                lines.append("Source: \(report.sourceName)")
                if report.reviewRequired {
                    lines.append("Approval is required before this source can sync automatically.")
                }
                lines.append("Found \(report.totalMatchedCount) matching \(report.totalMatchedCount == 1 ? "booking" : "bookings").")

                let createStatus = previewOnly ? "would create" : "created"
                let updateStatus = previewOnly ? "would update" : "updated"
                let deleteStatus = previewOnly ? "would delete" : "deleted"
                let createCount = report.actions.filter { $0.status == createStatus }.count
                let updateCount = report.actions.filter { $0.status == updateStatus }.count
                let deleteCount = report.actions.filter { $0.status == deleteStatus }.count
                let unchangedCount = report.actions.filter { $0.status == "unchanged" }.count

                if report.filteredPastCount > 0 {
                    lines.append("Skipped \(report.filteredPastCount) past \(report.filteredPastCount == 1 ? "booking" : "bookings").")
                }

                if createCount > 0 {
                    lines.append(previewOnly ? "Ready to add \(createCount) future \(createCount == 1 ? "event" : "events")." : "Added \(createCount) future \(createCount == 1 ? "event" : "events").")
                }
                if updateCount > 0 {
                    lines.append(previewOnly ? "Ready to update \(updateCount) future \(updateCount == 1 ? "event" : "events")." : "Updated \(updateCount) future \(updateCount == 1 ? "event" : "events").")
                }
                if deleteCount > 0 {
                    lines.append(previewOnly ? "Ready to remove \(deleteCount) future \(deleteCount == 1 ? "event" : "events")." : "Removed \(deleteCount) future \(deleteCount == 1 ? "event" : "events").")
                }
                if createCount == 0 && updateCount == 0 && deleteCount == 0 {
                    if unchangedCount > 0 {
                        lines.append("Future calendar is already up to date.")
                    } else {
                        lines.append(previewOnly ? "No future events need to be added right now." : "No calendar changes were needed.")
                    }
                }

                let changedActions = report.actions.filter { $0.status != "unchanged" }
                if !changedActions.isEmpty {
                    lines.append(previewOnly ? "Planned changes:" : "Completed changes:")
                    for action in changedActions {
                        lines.append("- \(customerFacingInterval(start: action.start, end: action.end))")
                    }
                }
                lines.append("")
            } catch {
                let message = error.localizedDescription
                let report = SourceSyncReport(
                    sourceItemID: source.id,
                    sourceName: source.name,
                    bookingID: source.bookingID,
                    calendarName: source.calendar,
                    parserLabel: "Failed",
                    parserNotes: [],
                    reviewRequired: false,
                    workbookFingerprint: nil,
                    averageConfidence: nil,
                    minimumConfidence: nil,
                    totalMatchedCount: 0,
                    syncedMatchedCount: 0,
                    filteredPastCount: 0,
                    actions: [],
                    deleteCandidates: [],
                    errorMessage: message
                )
                reports.append(report)
                lines.append("Source: \(source.name)")
                lines.append("Could not complete sync for this source.")
                lines.append("Reason: \(message)")
                lines.append("")
            }
        }

        if !previewOnly {
            SettingsStore.saveState(state)
        }
        return SyncRunResult(reports: reports, outputText: lines.joined(separator: "\n"))
    }

    private func syncSource(
        source: SourceItem,
        extraction: ExtractionResult,
        state: inout SyncState,
        previewOnly: Bool,
        aiApprovals: [AIApprovalRecord]
    ) throws -> SourceSyncReport {
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == source.calendar }) else {
            throw AppFailure.calendarNotFound(source.calendar)
        }

        if !previewOnly, extraction.reviewRequired {
            let sourceKey = sourceIdentity(for: source)
            let isApproved = aiApprovals.contains {
                $0.sourceKey == sourceKey && $0.workbookFingerprint == extraction.workbookFingerprint
            }
            if !isApproved {
                throw AppFailure.syncFailed("AI parse needs review first. Run Preview, then click Approve AI before Sync.")
            }
        }

        var actions: [EventAction] = []
        let events = extraction.filteredEvents
        let activeKeys = Set(events.map(\.syncKey))

        for event in events {
            let customURL = URL(string: "ppms-sync://event/\(event.syncKey)")!
            let existingRecord = state.events[event.syncKey]
            let existingEvent = findExistingEvent(for: event, stateRecord: existingRecord, calendar: calendar, customURL: customURL)
            let target = existingEvent ?? EKEvent(eventStore: store)
            let oldSignature = existingEvent.map(eventSignature) ?? ""

            target.calendar = calendar
            target.title = event.sourceName
            target.startDate = event.start
            target.endDate = event.end
            target.isAllDay = event.isAllDay
            target.notes = event.sourceLink
            target.url = customURL

            let newSignature = eventSignature(target)
            let status: String
            if existingEvent == nil {
                status = previewOnly ? "would create" : "created"
                if !previewOnly {
                    try store.save(target, span: .thisEvent, commit: true)
                }
            } else if oldSignature != newSignature {
                status = previewOnly ? "would update" : "updated"
                if !previewOnly {
                    try store.save(target, span: .thisEvent, commit: true)
                }
            } else {
                status = "unchanged"
            }

            actions.append(EventAction(status: status, title: event.sourceName, start: event.start, end: event.end))
            if !previewOnly, let identifier = target.eventIdentifier {
                state.events[event.syncKey] = StoredEvent(
                    eventIdentifier: identifier,
                    sourceID: event.sourceID,
                    calendar: event.calendarName,
                    title: event.sourceName,
                    startISO: iso8601(event.start),
                    endISO: iso8601(event.end)
                )
            }
        }

        let staleEntries = state.events.compactMap { key, value -> DeleteCandidate? in
            guard value.sourceID == sourceIdentity(for: source) else {
                return nil
            }
            guard !activeKeys.contains(key) else { return nil }
            return DeleteCandidate(
                syncKey: key,
                eventIdentifier: value.eventIdentifier,
                title: value.title,
                startISO: value.startISO,
                endISO: value.endISO
            )
        }.sorted { $0.startISO < $1.startISO }

        var deleteCandidates: [DeleteCandidate] = []
        for candidate in staleEntries {
            if !previewOnly {
                if let event = findStaleEvent(candidate: candidate, calendar: calendar) {
                    try store.remove(event, span: .thisEvent, commit: true)
                }
                state.events.removeValue(forKey: candidate.syncKey)
            }
            if let start = parseFlexibleISO8601(candidate.startISO, timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current),
               let end = parseFlexibleISO8601(candidate.endISO, timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current) {
                actions.append(
                    EventAction(
                        status: previewOnly ? "would delete" : "deleted",
                        title: candidate.title,
                        start: start,
                        end: end
                    )
                )
            }
            deleteCandidates.append(candidate)
        }

        return SourceSyncReport(
            sourceItemID: source.id,
            sourceName: source.name,
            bookingID: source.bookingID,
            calendarName: source.calendar,
            parserLabel: extraction.parserLabel,
            parserNotes: extraction.parserNotes,
            reviewRequired: extraction.reviewRequired,
            workbookFingerprint: extraction.workbookFingerprint,
            averageConfidence: extraction.averageConfidence,
            minimumConfidence: extraction.minimumConfidence,
            totalMatchedCount: extraction.allEvents.count,
            syncedMatchedCount: events.count,
            filteredPastCount: extraction.filteredPastCount,
            actions: actions,
            deleteCandidates: deleteCandidates,
            errorMessage: nil
        )
    }

    private func findExistingEvent(for event: ReservationEvent, stateRecord: StoredEvent?, calendar: EKCalendar, customURL: URL) -> EKEvent? {
        if let stateRecord,
           let item = store.calendarItem(withIdentifier: stateRecord.eventIdentifier) as? EKEvent {
            return item
        }

        let start = Calendar.current.date(byAdding: .day, value: -2, to: event.start) ?? event.start
        let end = Calendar.current.date(byAdding: .day, value: 2, to: event.end) ?? event.end
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).first(where: { $0.url == customURL })
    }

    private func findStaleEvent(candidate: DeleteCandidate, calendar: EKCalendar) -> EKEvent? {
        if let item = store.calendarItem(withIdentifier: candidate.eventIdentifier) as? EKEvent {
            return item
        }

        guard let start = parseFlexibleISO8601(candidate.startISO, timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current),
              let end = parseFlexibleISO8601(candidate.endISO, timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current) else {
            return nil
        }
        let predicate = store.predicateForEvents(
            withStart: Calendar.current.date(byAdding: .day, value: -2, to: start) ?? start,
            end: Calendar.current.date(byAdding: .day, value: 2, to: end) ?? end,
            calendars: [calendar]
        )
        let expectedURL = URL(string: "ppms-sync://event/\(candidate.syncKey)")
        return store.events(matching: predicate).first(where: { $0.url == expectedURL })
    }

    private func ensureAccess() async throws {
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToEvents()
            if !granted { throw AppFailure.calendarAccessDenied }
        } else {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            if !granted { throw AppFailure.calendarAccessDenied }
        }
    }
}

private func eventSignature(_ event: EKEvent) -> String {
    "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)|\(event.isAllDay)|\(event.notes ?? "")|\(event.url?.absoluteString ?? "")|\(event.calendar?.title ?? "")"
}

private func digest(_ text: String) -> String {
    let data = Data(text.utf8)
    let digest = data.withUnsafeBytes { buffer in
        Array(buffer)
    }.reduce(into: UInt64(1469598103934665603)) { hash, byte in
        hash = (hash ^ UInt64(byte)) &* 1099511628211
    }
    return String(format: "%016llx", digest)
}

private func deterministicUUID(for text: String) -> UUID {
    let hash = SHA256.hash(data: Data(text.utf8))
    var bytes = Array(hash.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    return formatter.string(from: date)
}

private func customerFacingInterval(start: Date, end: Date) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let sameDay = calendar.isDate(start, inSameDayAs: end)

    let dayFormatter = DateFormatter()
    dayFormatter.calendar = calendar
    dayFormatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.dateFormat = "yyyy-MM-dd"

    let timeFormatter = DateFormatter()
    timeFormatter.calendar = calendar
    timeFormatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")
    timeFormatter.dateFormat = "HH:mm"

    let dateTimeFormatter = DateFormatter()
    dateTimeFormatter.calendar = calendar
    dateTimeFormatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm"

    if sameDay {
        return "\(dayFormatter.string(from: start)) \(timeFormatter.string(from: start))-\(timeFormatter.string(from: end))"
    }
    return "\(dateTimeFormatter.string(from: start)) -> \(dateTimeFormatter.string(from: end))"
}

private func customerFacingDeleteCandidate(_ candidate: DeleteCandidate) -> String {
    let timeZone = TimeZone(identifier: "Asia/Singapore") ?? .current
    if let start = parseFlexibleISO8601(candidate.startISO, timeZone: timeZone),
       let end = parseFlexibleISO8601(candidate.endISO, timeZone: timeZone) {
        return customerFacingInterval(start: start, end: end)
    }
    return "\(candidate.startISO) -> \(candidate.endISO)"
}

private func parseMonthSheet(_ title: String) -> (Int, Int)? {
    let yearRegex = try! NSRegularExpression(pattern: "(20\\d{2})")
    guard let match = yearRegex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
          let range = Range(match.range(at: 1), in: title),
          let year = Int(title[range]) else { return nil }
    let compact = title.lowercased().replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
    for alias in monthAliases.keys.sorted(by: { $0.count > $1.count }) {
        if compact.hasPrefix(alias), let month = monthAliases[alias] {
            return (year, month)
        }
    }
    return nil
}

private func dayNumber(from text: String) -> Int? {
    if let value = Int(text) {
        return (1...31).contains(value) ? value : nil
    }
    if let value = Double(text), value.rounded() == value {
        let intValue = Int(value)
        return (1...31).contains(intValue) ? intValue : nil
    }
    return nil
}

private func decodeCellReference(_ reference: String) -> (Int, Int)? {
    let letters = reference.prefix { $0.isLetter }
    let numbers = String(reference.reversed().prefix { $0.isNumber }.reversed())
    guard !letters.isEmpty, let row = Int(numbers) else { return nil }
    var column = 0
    for scalar in letters.uppercased().unicodeScalars {
        column = column * 26 + Int(scalar.value) - 64
    }
    return (row, column)
}

private func columnLetters(_ value: Int) -> String {
    var value = value
    var output = ""
    while value > 0 {
        let remainder = (value - 1) % 26
        output = String(UnicodeScalar(65 + remainder)!) + output
        value = (value - 1) / 26
    }
    return output
}

private func clockString(fromMinutes minutes: Int) -> String {
    let normalized = ((minutes % (24 * 60)) + (24 * 60)) % (24 * 60)
    let hour = normalized / 60
    let minute = normalized % 60
    return String(format: "%02d:%02d", hour, minute)
}

private func buildWorkdayRange(
    on baseDate: Date,
    workdayHours: WorkdayHours,
    calendar: Calendar,
    timeZone: TimeZone
) -> (Date, Date)? {
    guard let start = try? buildDate(from: baseDate, timeString: workdayHours.start, in: timeZone),
          let rawEnd = try? buildDate(from: baseDate, timeString: workdayHours.end, in: timeZone) else {
        return nil
    }
    let end = rawEnd > start ? rawEnd : (calendar.date(byAdding: .day, value: 1, to: rawEnd) ?? rawEnd)
    return (start, end)
}

private func buildDate(from baseDate: Date, timeString: String, in timeZone: TimeZone) throws -> Date {
    let parts = timeString.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
        throw AppFailure.invalidTime(timeString)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: baseDate)
    var full = DateComponents()
    full.year = components.year
    full.month = components.month
    full.day = components.day
    full.hour = hour
    full.minute = minute
    full.timeZone = timeZone
    guard let date = calendar.date(from: full) else {
        throw AppFailure.invalidTime(timeString)
    }
    return date
}

private func parseFlexibleISO8601(_ value: String, timeZone: TimeZone) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: trimmed) {
        return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: trimmed) {
        return date
    }

    let dateOnly = DateFormatter()
    dateOnly.calendar = Calendar(identifier: .gregorian)
    dateOnly.timeZone = timeZone
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.dateFormat = "yyyy-MM-dd"
    return dateOnly.date(from: trimmed)
}

private func normalizeWorkbookPath(_ target: String) -> String {
    if target.hasPrefix("xl/") {
        return target
    }
    if target.hasPrefix("/xl/") {
        return String(target.dropFirst())
    }
    return "xl/\(target)"
}

private func imageMimeType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "png":
        return "image/png"
    case "jpg", "jpeg":
        return "image/jpeg"
    case "webp":
        return "image/webp"
    case "gif":
        return "image/gif"
    case "heic":
        return "image/heic"
    case "heif":
        return "image/heif"
    default:
        return nil
    }
}

private func localImageURL(from source: String) -> URL? {
    let expanded = NSString(string: source).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else {
        return nil
    }
    let url = URL(fileURLWithPath: expanded)
    guard imageMimeType(for: url) != nil else {
        return nil
    }
    return url
}

private func downloadWorkbook(from source: String) async throws -> URL {
    let expanded = NSString(string: source).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded) {
        return URL(fileURLWithPath: expanded)
    }

    let downloadURL: URL
    if source.contains("docs.google.com/spreadsheets") {
        let pattern = "/d/([a-zA-Z0-9-_]+)"
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else {
            throw AppFailure.invalidSource
        }
        let sheetID = String(source[range])
        guard let url = URL(string: "https://docs.google.com/spreadsheets/d/\(sheetID)/export?format=xlsx") else {
            throw AppFailure.invalidSource
        }
        downloadURL = url
    } else if let url = URL(string: source), let scheme = url.scheme, scheme.hasPrefix("http") {
        downloadURL = url
    } else {
        throw AppFailure.unsupportedSource(source)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpAdditionalHeaders = [
        "User-Agent": "PPMSCalendarSync/1.0"
    ]
    let session = URLSession(configuration: configuration)
    let request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    let (tempURL, response) = try await session.download(for: request)
    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
        throw AppFailure.syncFailed("Workbook download failed with HTTP \(httpResponse.statusCode).")
    }
    let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("ppms-\(UUID().uuidString).xlsx")
    try? FileManager.default.removeItem(at: finalURL)
    try FileManager.default.moveItem(at: tempURL, to: finalURL)
    return finalURL
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [SourceItem]
    @Published var sourceStatuses: [UUID: SourceRuntimeStatus]
    @Published var workdayStart: String
    @Published var workdayEnd: String
    @Published var selectedSourceID: UUID?
    @Published var draftEnabled = true
    @Published var draftName = ""
    @Published var draftSource = ""
    @Published var draftBookingID = ""
    @Published var draftCalendar = "Experiment"
    @Published var calendars: [String] = ["Experiment"]
    @Published var calendarAccessState: CalendarAccessState = .unknown
    @Published var output = ""
    @Published var status = "Ready"
    @Published var isBusy = false
    @Published var isCalendarLoading = false
    @Published var autoSyncEnabled: Bool
    @Published var autoSyncMinutes: String
    @Published var upcomingOnly: Bool
    @Published var confirmBeforeSync: Bool
    @Published var confirmBeforeDeletion: Bool
    @Published var menuBarModeEnabled: Bool
    @Published var parserMode: ParserMode
    @Published var aiProvider: AIProvider
    @Published var aiEndpointURL: String
    @Published var aiModel: String
    @Published var aiAPIKey: String
    @Published var aiApprovals: [AIApprovalRecord]
    @Published var pendingAIReviews: [PendingAIReview] = []
    @Published var pendingSyncConfirmation: PendingSyncConfirmation?
    @Published var showAdvancedAISettings = false

    private let engine = CalendarSyncEngine()
    private let launchAutomation = LaunchAutomation.load()
    private var timer: Timer?
    private var persistTask: Task<Void, Never>?
    private var lastPersistedSettingsData = Data()
    private var lastPersistedAIAPIKey = ""

    init() {
        let settings = SettingsStore.loadSettings()
        self.sources = settings.sources
        self.sourceStatuses = Dictionary(uniqueKeysWithValues: settings.sources.map { ($0.id, .idle) })
        self.workdayStart = settings.workdayHours.start
        self.workdayEnd = settings.workdayHours.end
        self.autoSyncEnabled = settings.autoSyncEnabled
        self.autoSyncMinutes = String(settings.autoSyncMinutes)
        self.upcomingOnly = settings.upcomingOnly
        self.confirmBeforeSync = settings.confirmBeforeSync
        self.confirmBeforeDeletion = settings.confirmBeforeDeletion
        self.menuBarModeEnabled = settings.menuBarModeEnabled
        self.parserMode = settings.parserMode
        self.aiProvider = settings.aiParser.provider
        self.aiEndpointURL = settings.aiParser.endpointURL
        let storedModel = settings.aiParser.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.aiParser.provider != .custom && storedModel == settings.aiParser.provider.defaultModel {
            self.aiModel = ""
        } else {
            self.aiModel = storedModel
        }
        let storedAIAPIKey = KeychainStore.loadAIAPIKey()
        self.aiAPIKey = storedAIAPIKey
        self.aiApprovals = settings.aiApprovals
        self.showAdvancedAISettings = false
        self.lastPersistedAIAPIKey = storedAIAPIKey
        self.lastPersistedSettingsData = Self.encodedSettingsData(
            sources: self.sources,
            workdayStart: self.workdayStart,
            workdayEnd: self.workdayEnd,
            autoSyncEnabled: self.autoSyncEnabled,
            autoSyncMinutes: self.autoSyncMinutes,
            upcomingOnly: self.upcomingOnly,
            confirmBeforeSync: self.confirmBeforeSync,
            confirmBeforeDeletion: self.confirmBeforeDeletion,
            menuBarModeEnabled: self.menuBarModeEnabled,
            parserMode: self.parserMode,
            aiProvider: self.aiProvider,
            aiEndpointURL: self.aiEndpointURL,
            aiModel: self.aiModel,
            aiApprovals: self.aiApprovals,
            lastDraft: settings.lastDraft
        )
        if let lastDraft = settings.lastDraft {
            self.selectedSourceID = lastDraft.selectedSourceID
            self.draftEnabled = lastDraft.enabled
            self.draftName = lastDraft.name
            self.draftSource = lastDraft.source
            self.draftBookingID = lastDraft.bookingID
            self.draftCalendar = lastDraft.calendar
            if let selectedSourceID = lastDraft.selectedSourceID,
               let selected = settings.sources.first(where: { $0.id == selectedSourceID }) {
                self.draftEnabled = selected.enabled
                self.draftName = selected.name
                self.draftSource = selected.source
                self.draftBookingID = selected.bookingID
                self.draftCalendar = selected.calendar
            }
        } else {
            if let first = settings.sources.first {
                self.selectedSourceID = first.id
                self.draftEnabled = first.enabled
                self.draftName = first.name
                self.draftSource = first.source
                self.draftBookingID = first.bookingID
                self.draftCalendar = first.calendar
            } else {
                let first = defaultSources()[0]
                self.sources = [first]
                self.selectedSourceID = first.id
                self.draftEnabled = first.enabled
                self.draftName = first.name
                self.draftSource = first.source
                self.draftBookingID = first.bookingID
                self.draftCalendar = first.calendar
            }
        }
        reconcileSourceStatuses()
        prepareCalendarsOnLaunch()
        rescheduleTimer()
        runLaunchAutomationIfNeeded()
    }

    deinit {
        timer?.invalidate()
        persistTask?.cancel()
    }

    func refreshCalendars() {
        if isBusy || isCalendarLoading { return }
        isCalendarLoading = true
        status = calendarAccessState == .notDetermined ? "Requesting Calendar access..." : "Loading calendars..."
        Task {
            do {
                let values = try await engine.calendarNames()
                calendarAccessState = .granted
                calendars = values.isEmpty ? ["Experiment"] : values
                if !calendars.contains(draftCalendar) {
                    draftCalendar = calendars.first ?? "Experiment"
                }
                output = ""
                status = values.isEmpty ? "No calendars found in Apple Calendar" : "Calendars loaded"
            } catch {
                let access = await engine.calendarAccessState()
                applyCalendarAccessState(access, fallbackMessage: error.localizedDescription)
            }
            isCalendarLoading = false
        }
    }

    func requestCalendarAccess() {
        switch calendarAccessState {
        case .denied, .restricted:
            openCalendarPrivacySettings()
        case .unknown, .notDetermined, .granted:
            refreshCalendars()
        }
    }

    func selectSource(_ item: SourceItem?) {
        guard let item else { return }
        if selectedSourceID != item.id {
            selectedSourceID = item.id
        }
        applyDraftFields(from: item)
        schedulePersist()
    }

    func newSource() {
        selectedSourceID = nil
        draftEnabled = true
        draftName = ""
        draftSource = ""
        draftBookingID = ""
        draftCalendar = calendars.first ?? "Experiment"
        status = "Editing a new source. Fill the fields and click Save."
        schedulePersist()
    }

    func saveCurrentSource() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = draftSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let booking = draftBookingID.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = draftCalendar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !source.isEmpty, !booking.isEmpty, !calendar.isEmpty else {
            status = "Fill in all source fields before saving"
            return
        }

        let item = SourceItem(
            id: selectedSourceID ?? UUID(),
            enabled: draftEnabled,
            name: name,
            source: source,
            bookingID: booking,
            calendar: calendar
        )

        if let selectedSourceID, let index = sources.firstIndex(where: { $0.id == selectedSourceID }) {
            sources[index] = item
        } else {
            sources.append(item)
        }

        selectedSourceID = item.id
        reconcileSourceStatuses()
        persistSettings()
        status = "Source saved"
    }

    func removeSelectedSource() {
        guard let selectedSourceID, let index = sources.firstIndex(where: { $0.id == selectedSourceID }) else { return }
        sources.remove(at: index)
        sourceStatuses.removeValue(forKey: selectedSourceID)
        if let next = sources.first {
            selectSource(next)
        } else {
            newSource()
        }
        reconcileSourceStatuses()
        persistSettings()
        status = "Source removed"
    }

    func workdayChanged() {
        schedulePersist()
    }

    func previewAll() {
        runSync(previewOnly: true)
    }

    func syncAll() {
        guard confirmBeforeSync || confirmBeforeDeletion else {
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
        pendingSyncConfirmation = nil
        runSync(previewOnly: false)
    }

    func cancelPendingSync() {
        pendingSyncConfirmation = nil
        status = "Sync cancelled"
    }

    func aiProviderChanged() {
        switch aiProvider {
        case .openAI, .deepSeek, .kimi, .anthropic, .gemini, .openRouter:
            aiEndpointURL = aiProvider.defaultEndpointURL
            aiModel = ""
        case .custom:
            let presetEndpoints = AIProvider.allCases
                .filter { $0 != .custom }
                .map(\.defaultEndpointURL)
            let presetModels = AIProvider.allCases
                .filter { $0 != .custom }
                .map(\.defaultModel)
            if presetEndpoints.contains(aiEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                aiEndpointURL = ""
            }
            if presetModels.contains(aiModel.trimmingCharacters(in: .whitespacesAndNewlines)) {
                aiModel = ""
            }
        }
        schedulePersist()
    }

    func approvePendingAIReviews() {
        guard !pendingAIReviews.isEmpty else { return }
        let newApprovals = pendingAIReviews.map {
            AIApprovalRecord(
                sourceKey: sourceApprovalKey(for: $0.sourceItemID),
                workbookFingerprint: $0.workbookFingerprint,
                approvedAtISO: iso8601(Date())
            )
        }

        for approval in newApprovals {
            if !aiApprovals.contains(where: { $0.sourceKey == approval.sourceKey && $0.workbookFingerprint == approval.workbookFingerprint }) {
                aiApprovals.append(approval)
            }
        }

        for review in pendingAIReviews {
            if case .review(let matchCount) = sourceStatuses[review.sourceItemID] {
                sourceStatuses[review.sourceItemID] = .success(matchCount: matchCount)
            }
        }
        pendingAIReviews = []
        persistSettings()
        status = "Approved AI layouts for future syncs"
    }

    func openCalendarApp() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseSourceFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xlsx"),
            UTType.png,
            UTType.jpeg,
            UTType.gif,
            UTType.webP,
            UTType(filenameExtension: "heic"),
            UTType(filenameExtension: "heif")
        ].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            if imageMimeType(for: url) != nil {
                startInstantImageImport(from: url)
            } else {
                _ = applySourceFile(url)
            }
        }
    }

    func handleDroppedSourceFiles(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        if imageMimeType(for: first) != nil {
            startInstantImageImport(from: first)
            return true
        }
        return applySourceFile(first)
    }

    private func startInstantImageImport(from imageURL: URL) {
        guard !isBusy else {
            status = "Wait for the current task to finish first"
            return
        }
        guard let source = makeInstantImageImportSource(from: imageURL) else {
            return
        }

        isBusy = true
        output = ""
        status = "Reading \(source.bookingID) schedule from image..."

        Task {
            do {
                let preview = try await engine.sync(
                    sources: [source],
                    workdayHours: WorkdayHours(
                        start: workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                        end: workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    upcomingOnly: false,
                    previewOnly: true,
                    parserMode: parserMode,
                    aiConfiguration: resolvedAIConfiguration,
                    aiApprovals: aiApprovals
                )

                guard let report = preview.reports.first, report.errorMessage == nil else {
                    output = preview.outputText
                    status = preview.reports.first?.errorMessage ?? "Could not read the dropped image"
                    isBusy = false
                    return
                }

                guard let plan = buildImageImportPlan(source: source, report: report, previewOutput: preview.outputText) else {
                    output = preview.outputText
                    status = "No matching \(source.bookingID) schedule items found in the dropped image"
                    isBusy = false
                    return
                }

                output = plan.previewOutput
                status = "Read \(plan.matchedCount) \(plan.matchedCount == 1 ? "schedule item" : "schedule items") from the dropped image"
                isBusy = false

                let shouldImport = presentImageImportConfirmation(plan)
                guard shouldImport else {
                    status = "Image import cancelled"
                    return
                }

                isBusy = true
                status = "Adding \(source.bookingID) schedule to Apple Calendar..."
                let syncResult = try await engine.sync(
                    sources: [source],
                    workdayHours: WorkdayHours(
                        start: workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                        end: workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    upcomingOnly: false,
                    previewOnly: false,
                    parserMode: parserMode,
                    aiConfiguration: resolvedAIConfiguration,
                    aiApprovals: imageImportApprovals(for: plan)
                )
                output = syncResult.outputText
                status = "Image schedule synced"
            } catch {
                output = error.localizedDescription
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func makeInstantImageImportSource(from imageURL: URL) -> SourceItem? {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookingID = draftBookingID.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = draftCalendar.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !bookingID.isEmpty, !calendar.isEmpty else {
            status = "Set Booking ID, Event Title, and Calendar before dropping an image"
            output = "Image import uses the current Booking ID, Event Title, and Calendar as context. Fill those fields first, then drop the timetable image again."
            return nil
        }

        let sourceKey = "image-import|\(name)|\(bookingID)|\(calendar)|\(imageURL.path)"
        return SourceItem(
            id: deterministicUUID(for: sourceKey),
            enabled: true,
            name: name,
            source: imageURL.path,
            bookingID: bookingID,
            calendar: calendar
        )
    }

    private func buildImageImportPlan(source: SourceItem, report: SourceSyncReport, previewOutput: String) -> ImageImportPlan? {
        guard report.totalMatchedCount > 0 else {
            return nil
        }

        let createCount = report.actions.filter { $0.status == "would create" }.count
        let updateCount = report.actions.filter { $0.status == "would update" }.count
        let deleteCount = report.actions.filter { $0.status == "would delete" }.count
        let sampleIntervals = report.actions
            .filter { ["would create", "would update", "would delete"].contains($0.status) }
            .map { customerFacingInterval(start: $0.start, end: $0.end) }

        return ImageImportPlan(
            source: source,
            matchedCount: report.totalMatchedCount,
            createCount: createCount,
            updateCount: updateCount,
            deleteCount: deleteCount,
            reviewRequired: report.reviewRequired,
            workbookFingerprint: report.workbookFingerprint,
            previewOutput: previewOutput,
            sampleIntervals: Array(sampleIntervals.prefix(8))
        )
    }

    private func imageImportApprovals(for plan: ImageImportPlan) -> [AIApprovalRecord] {
        guard plan.reviewRequired, let workbookFingerprint = plan.workbookFingerprint else {
            return aiApprovals
        }
        let temporaryApproval = AIApprovalRecord(
            sourceKey: sourceIdentity(for: plan.source),
            workbookFingerprint: workbookFingerprint,
            approvedAtISO: iso8601(Date())
        )
        if aiApprovals.contains(where: { $0.sourceKey == temporaryApproval.sourceKey && $0.workbookFingerprint == temporaryApproval.workbookFingerprint }) {
            return aiApprovals
        }
        return aiApprovals + [temporaryApproval]
    }

    private func presentImageImportConfirmation(_ plan: ImageImportPlan) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Read \(plan.source.bookingID) schedule: \(plan.matchedCount) \(plan.matchedCount == 1 ? "item" : "items")"

        var lines: [String] = []
        lines.append("Event title: \(plan.source.name)")
        lines.append("Calendar: \(plan.source.calendar)")
        lines.append("Add: \(plan.createCount)   Update: \(plan.updateCount)   Remove: \(plan.deleteCount)")
        if plan.reviewRequired {
            lines.append("")
            lines.append("This image needed AI interpretation. Please double-check the preview dates below before importing.")
        }
        if !plan.sampleIntervals.isEmpty {
            lines.append("")
            lines.append("Preview:")
            for interval in plan.sampleIntervals {
                lines.append("• \(interval)")
            }
            let hiddenCount = max(plan.createCount + plan.updateCount + plan.deleteCount - plan.sampleIntervals.count, 0)
            if hiddenCount > 0 {
                lines.append("• +\(hiddenCount) more")
            }
        }
        lines.append("")
        lines.append("Add these schedule items to Apple Calendar?")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Add to Calendar")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runSync(previewOnly: Bool) {
        if isBusy { return }
        let enabledSources = sources.filter(\.enabled)
        guard !enabledSources.isEmpty else {
            status = "Enable at least one source first"
            return
        }
        if !previewOnly {
            let enabledIDs = Set(enabledSources.map(\.id))
            let blockingReviews = pendingAIReviews.filter { enabledIDs.contains($0.sourceItemID) }
            if !blockingReviews.isEmpty {
                let names = blockingReviews.map(\.sourceName).joined(separator: ", ")
                status = "Approve AI layouts before syncing"
                output = "AI review is still required for: \(names)\nRun Approve AI first, or Preview again after changing the parser settings."
                return
            }
        }

        isBusy = true
        output = ""
        status = previewOnly ? "Previewing..." : "Syncing..."
        setLoadingStatuses(for: enabledSources)

        Task {
            do {
                let result = try await engine.sync(
                    sources: enabledSources,
                    workdayHours: WorkdayHours(
                        start: workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                        end: workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    upcomingOnly: upcomingOnly,
                    previewOnly: previewOnly,
                    parserMode: parserMode,
                    aiConfiguration: resolvedAIConfiguration,
                    aiApprovals: aiApprovals
                )
                output = result.outputText
                if previewOnly {
                    pendingAIReviews = pendingReviews(from: result.reports)
                } else {
                    pendingAIReviews = []
                }
                applySourceStatuses(from: result.reports)
                status = previewOnly ? "Preview complete" : "Sync complete"
            } catch {
                output = error.localizedDescription
                if previewOnly {
                    pendingAIReviews = []
                }
                clearLoadingStatuses()
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func prepareCalendarsOnLaunch() {
        Task {
            let access = await engine.calendarAccessState()
            applyCalendarAccessState(access, fallbackMessage: nil)
            guard access.hasUsableAccess, let values = await engine.calendarNamesIfAuthorized() else {
                return
            }
            applyLoadedCalendars(values, statusMessage: values.isEmpty ? "No calendars found in Apple Calendar" : "Calendars loaded")
        }
    }

    private func applyLoadedCalendars(_ values: [String], statusMessage: String) {
        calendarAccessState = .granted
        calendars = values.isEmpty ? ["Experiment"] : values
        if !calendars.contains(draftCalendar) {
            draftCalendar = calendars.first ?? "Experiment"
        }
        output = ""
        status = statusMessage
    }

    private func applyCalendarAccessState(_ access: CalendarAccessState, fallbackMessage: String?) {
        calendarAccessState = access
        switch access {
        case .unknown:
            status = fallbackMessage ?? "Ready"
            if let fallbackMessage {
                output = fallbackMessage
            } else {
                output = ""
            }
        case .notDetermined:
            status = "Calendar access needed"
            output = fallbackMessage ?? ""
        case .granted:
            status = fallbackMessage ?? status
            if let fallbackMessage {
                output = fallbackMessage
            } else if output == access.helperText {
                output = ""
            }
        case .denied, .restricted:
            status = access == .denied ? "Calendar access is off" : "Calendar access is restricted"
            output = fallbackMessage ?? ""
        }
    }

    private func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
        status = "Opened Calendar privacy settings"
    }

    private func applySourceFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard isSupportedSourceFile(url) else {
            status = "Unsupported file type"
            output = "Drop an image or .xlsx workbook, or paste a Google Sheets link."
            return false
        }
        draftSource = url.path
        output = ""
        status = "Selected source file"
        schedulePersist()
        return true
    }

    private func applyDraftFields(from item: SourceItem) {
        if draftEnabled != item.enabled {
            draftEnabled = item.enabled
        }
        if draftName != item.name {
            draftName = item.name
        }
        if draftSource != item.source {
            draftSource = item.source
        }
        if draftBookingID != item.bookingID {
            draftBookingID = item.bookingID
        }
        if draftCalendar != item.calendar {
            draftCalendar = item.calendar
        }
    }

    private func currentDraftState() -> DraftEditorState {
        DraftEditorState(
            selectedSourceID: selectedSourceID,
            enabled: draftEnabled,
            name: draftName,
            source: draftSource,
            bookingID: draftBookingID,
            calendar: draftCalendar
        )
    }

    private func isSupportedSourceFile(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "xlsx" {
            return true
        }
        return imageMimeType(for: url) != nil
    }

    func runtimeStatus(for item: SourceItem) -> SourceRuntimeStatus {
        sourceStatuses[item.id] ?? .idle
    }

    private func schedulePersist(delayNanoseconds: UInt64 = 250_000_000) {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.settingsSnapshot()
            let apiKey = self.aiAPIKey
            if snapshot.data == self.lastPersistedSettingsData, apiKey == self.lastPersistedAIAPIKey {
                return
            }
            self.lastPersistedSettingsData = snapshot.data
            self.lastPersistedAIAPIKey = apiKey
            Task.detached(priority: .utility) {
                KeychainStore.saveAIAPIKey(apiKey)
                SettingsStore.saveSettings(snapshot.settings)
            }
        }
    }

    private func persistSettings() {
        let snapshot = settingsSnapshot()
        let apiKey = aiAPIKey
        lastPersistedSettingsData = snapshot.data
        lastPersistedAIAPIKey = apiKey
        Task.detached(priority: .utility) {
            KeychainStore.saveAIAPIKey(apiKey)
            SettingsStore.saveSettings(snapshot.settings)
        }
    }

    private func settingsSnapshot() -> (settings: AppSettings, data: Data) {
        let settings = AppSettings(
            sources: sources,
            workdayHours: WorkdayHours(
                start: workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                end: workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            autoSyncEnabled: autoSyncEnabled,
            autoSyncMinutes: max(Int(autoSyncMinutes) ?? 15, 1),
            upcomingOnly: upcomingOnly,
            confirmBeforeSync: confirmBeforeSync,
            confirmBeforeDeletion: confirmBeforeDeletion,
            menuBarModeEnabled: menuBarModeEnabled,
            parserMode: parserMode,
            aiParser: AIParserSettings(
                provider: aiProvider,
                endpointURL: aiEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            aiApprovals: aiApprovals,
            lastDraft: currentDraftState()
        )
        let data = (try? JSONEncoder().encode(settings)) ?? Data()
        return (settings, data)
    }

    private static func encodedSettingsData(
        sources: [SourceItem],
        workdayStart: String,
        workdayEnd: String,
        autoSyncEnabled: Bool,
        autoSyncMinutes: String,
        upcomingOnly: Bool,
        confirmBeforeSync: Bool,
        confirmBeforeDeletion: Bool,
        menuBarModeEnabled: Bool,
        parserMode: ParserMode,
        aiProvider: AIProvider,
        aiEndpointURL: String,
        aiModel: String,
        aiApprovals: [AIApprovalRecord],
        lastDraft: DraftEditorState?
    ) -> Data {
        let settings = AppSettings(
            sources: sources,
            workdayHours: WorkdayHours(
                start: workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                end: workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            autoSyncEnabled: autoSyncEnabled,
            autoSyncMinutes: max(Int(autoSyncMinutes) ?? 15, 1),
            upcomingOnly: upcomingOnly,
            confirmBeforeSync: confirmBeforeSync,
            confirmBeforeDeletion: confirmBeforeDeletion,
            menuBarModeEnabled: menuBarModeEnabled,
            parserMode: parserMode,
            aiParser: AIParserSettings(
                provider: aiProvider,
                endpointURL: aiEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            aiApprovals: aiApprovals,
            lastDraft: lastDraft
        )
        return (try? JSONEncoder().encode(settings)) ?? Data()
    }

    private func reconcileSourceStatuses() {
        var next = sourceStatuses.filter { key, _ in sources.contains(where: { $0.id == key }) }
        for item in sources where next[item.id] == nil {
            next[item.id] = .idle
        }
        sourceStatuses = next
    }

    private func setLoadingStatuses(for activeSources: [SourceItem]) {
        reconcileSourceStatuses()
        let activeIDs = Set(activeSources.map(\.id))
        for item in sources {
            if activeIDs.contains(item.id) {
                sourceStatuses[item.id] = .loading
            } else if !item.enabled {
                sourceStatuses[item.id] = .idle
            }
        }
    }

    private func clearLoadingStatuses() {
        reconcileSourceStatuses()
        for item in sources where sourceStatuses[item.id] == .loading {
            sourceStatuses[item.id] = .idle
        }
    }

    private func applySourceStatuses(from reports: [SourceSyncReport]) {
        reconcileSourceStatuses()
        for report in reports {
            if let message = report.errorMessage {
                sourceStatuses[report.sourceItemID] = .failure(message)
            } else if report.reviewRequired {
                sourceStatuses[report.sourceItemID] = .review(matchCount: report.totalMatchedCount)
            } else {
                sourceStatuses[report.sourceItemID] = .success(matchCount: report.totalMatchedCount)
            }
        }
    }

    private var resolvedAIConfiguration: AIServiceConfiguration? {
        let provider = aiProvider
        let endpoint = aiEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEndpoint = endpoint.isEmpty ? provider.defaultEndpointURL : endpoint
        guard !apiKey.isEmpty, !resolvedEndpoint.isEmpty, let url = URL(string: resolvedEndpoint) else {
            return nil
        }
        if provider == .custom && model.isEmpty {
            return nil
        }
        return AIServiceConfiguration(provider: provider, endpointURL: url, apiKey: apiKey, model: model)
    }

    private func pendingReviews(from reports: [SourceSyncReport]) -> [PendingAIReview] {
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

    private func sourceApprovalKey(for sourceID: UUID) -> String {
        guard let item = sources.first(where: { $0.id == sourceID }) else {
            return sourceID.uuidString
        }
        return sourceIdentity(for: item)
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoSyncEnabled else { return }
        let minutes = max(Int(autoSyncMinutes) ?? 15, 1)
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.runAutomatedSync()
            }
        }
    }

    private func runAutomatedSync() {
        if isBusy { return }
        if confirmBeforeSync {
            status = "Auto sync is waiting for manual confirmation"
            return
        }
        if confirmBeforeDeletion {
            previewForAutomatedDeletionSafety()
            return
        }
        runSync(previewOnly: false)
    }

    private func prepareSyncConfirmation() {
        if isBusy { return }
        let enabledSources = sources.filter(\.enabled)
        guard !enabledSources.isEmpty else {
            status = "Enable at least one source first"
            return
        }

        isBusy = true
        output = ""
        status = "Checking sync changes..."
        setLoadingStatuses(for: enabledSources)

        Task {
            do {
                let result = try await engine.sync(
                    sources: enabledSources,
                    workdayHours: WorkdayHours(
                        start: workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                        end: workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    upcomingOnly: upcomingOnly,
                    previewOnly: true,
                    parserMode: parserMode,
                    aiConfiguration: resolvedAIConfiguration,
                    aiApprovals: aiApprovals
                )
                output = result.outputText
                pendingAIReviews = pendingReviews(from: result.reports)
                applySourceStatuses(from: result.reports)

                let hasErrors = result.reports.contains { $0.errorMessage != nil }
                if hasErrors {
                    status = "Fix source errors before syncing"
                } else if !pendingAIReviews.isEmpty {
                    status = "Approve AI layouts before syncing"
                } else if let confirmation = buildSyncConfirmation(from: result.reports) {
                    pendingSyncConfirmation = confirmation
                    status = "Review sync changes"
                } else if hasNonDeleteChanges(in: result.reports) {
                    status = "Applying sync changes..."
                    isBusy = false
                    runSync(previewOnly: false)
                    return
                } else {
                    status = "No changes to sync"
                }
            } catch {
                output = error.localizedDescription
                pendingAIReviews = []
                clearLoadingStatuses()
                status = error.localizedDescription
            }
            isBusy = false
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

        let shouldPrompt = confirmBeforeSync
            ? (createCount + updateCount + deleteCount > 0)
            : (confirmBeforeDeletion && deleteCount > 0)
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
        let enabledSources = sources.filter(\.enabled)
        guard !enabledSources.isEmpty else {
            status = "Enable at least one source first"
            return
        }

        isBusy = true
        status = "Checking automated sync changes..."
        setLoadingStatuses(for: enabledSources)

        Task {
            do {
                let result = try await engine.sync(
                    sources: enabledSources,
                    workdayHours: WorkdayHours(
                        start: workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                        end: workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    upcomingOnly: upcomingOnly,
                    previewOnly: true,
                    parserMode: parserMode,
                    aiConfiguration: resolvedAIConfiguration,
                    aiApprovals: aiApprovals
                )
                output = result.outputText
                pendingAIReviews = pendingReviews(from: result.reports)
                applySourceStatuses(from: result.reports)

                let deleteCount = result.reports.reduce(0) { count, report in
                    count + report.actions.filter { $0.status == "would delete" }.count
                }
                let hasErrors = result.reports.contains { $0.errorMessage != nil }
                if hasErrors {
                    status = "Auto sync found source errors"
                } else if !pendingAIReviews.isEmpty {
                    status = "Auto sync is waiting for AI approval"
                } else if deleteCount > 0 {
                    status = "Auto sync found removed events waiting for manual confirmation"
                } else if hasNonDeleteChanges(in: result.reports) {
                    isBusy = false
                    runSync(previewOnly: false)
                    return
                } else {
                    status = "Auto sync checked: no changes"
                }
            } catch {
                output = error.localizedDescription
                clearLoadingStatuses()
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func runLaunchAutomationIfNeeded() {
        guard let launchAutomation else { return }
        let enabledSources = (launchAutomation.sources ?? sources).filter(\.enabled)
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
                start: workdayStart.trimmingCharacters(in: .whitespacesAndNewlines),
                end: workdayEnd.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let effectiveUpcomingOnly = launchAutomation.upcomingOnly ?? upcomingOnly
            let effectiveParserMode = launchAutomation.parserMode ?? parserMode
            let effectiveAIConfiguration = launchAutomationAIConfiguration(launchAutomation) ?? resolvedAIConfiguration
            do {
                let result = try await engine.sync(
                    sources: enabledSources,
                    workdayHours: effectiveWorkdayHours,
                    upcomingOnly: effectiveUpcomingOnly,
                    previewOnly: previewOnly,
                    parserMode: effectiveParserMode,
                    aiConfiguration: effectiveAIConfiguration,
                    aiApprovals: aiApprovals
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

struct WorkdayHoursEditor: View {
    @Binding var start: String
    @Binding var end: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                startField
                endField
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                startField
                endField
            }
        }
        .controlSize(.small)
    }

    private var startField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Start")
            TextField("10:00", text: $start)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 88, idealWidth: 96, maxWidth: 120, alignment: .leading)
        }
    }

    private var endField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "End")
            TextField("20:00", text: $end)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 88, idealWidth: 96, maxWidth: 120, alignment: .leading)
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
        }
        .frame(minWidth: 88, idealWidth: 94, maxWidth: 100, alignment: .leading)
        .frame(minHeight: 56, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct PaneHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FieldLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

struct SourceDropZone: View {
    let dropAction: ([URL]) -> Bool

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop an image for instant import")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text("The current Booking ID, Event Title, and Calendar will be used. Drop .xlsx files here only if you want to replace the saved source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isTargeted ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .dropDestination(for: URL.self) { items, _ in
            dropAction(items)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    private enum QuickActionLayoutMode {
        case singleRow
        case pairedRows
        case singleColumn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerPane
            primaryActionsPane

            HSplitView {
                sidebarPane
                    .frame(minWidth: 150, idealWidth: 205, maxWidth: 320, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                ScrollView {
                    detailColumn
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(minWidth: 640, minHeight: 620)
        .alert(item: $model.pendingSyncConfirmation) { confirmation in
            Alert(
                title: Text("Confirm Sync"),
                message: Text(confirmation.message),
                primaryButton: .default(Text("Continue")) {
                    model.confirmPendingSync()
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    model.cancelPendingSync()
                }
            )
        }
    }

    private func deferredBinding<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { newValue in
                guard model[keyPath: keyPath] != newValue else { return }
                DispatchQueue.main.async {
                    model[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func clearInputFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

    private var activityPlaceholder: (symbol: String, title: String, message: String)? {
        if model.calendarAccessState == .notDetermined {
            return (
                "calendar.badge.exclamationmark",
                "Calendar access needed",
                "Click Grant Calendar Access once to load your calendars."
            )
        }
        if model.calendarAccessState == .denied {
            return (
                "calendar.badge.exclamationmark",
                "Calendar access is off",
                "Open Calendar Settings, turn access on for \(appDisplayName), then refresh calendars."
            )
        }
        if model.calendarAccessState == .restricted {
            return (
                "calendar.badge.exclamationmark",
                "Calendar access is restricted",
                "This Mac is blocking calendar access for \(appDisplayName). Check device or privacy restrictions."
            )
        }
        if model.output.isEmpty {
            return (
                "clock.arrow.circlepath",
                "No activity yet",
                "Preview, sync, or drop an image to see activity here."
            )
        }
        return nil
    }

    fileprivate var detailColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorPane
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var summaryPane: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                SummaryCard(title: "Sources", value: "\(model.sources.count)", symbol: "square.stack.3d.up")
                SummaryCard(title: "Active", value: "\(model.sources.filter(\.enabled).count)", symbol: "checkmark.circle")
                SummaryCard(title: "Calendars", value: "\(model.calendars.count)", symbol: "calendar")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                SummaryCard(title: "Sources", value: "\(model.sources.count)", symbol: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
                SummaryCard(title: "Active", value: "\(model.sources.filter(\.enabled).count)", symbol: "checkmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                SummaryCard(title: "Calendars", value: "\(model.calendars.count)", symbol: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    fileprivate var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourcesPane
            Divider()
            outputPane
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var headerPane: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appDisplayName)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(appTagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    headerStatusPane
                        .frame(maxWidth: 360, alignment: .leading)
                }

                Spacer(minLength: 12)

                summaryPane
                    .frame(idealWidth: 240, maxWidth: 300, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appDisplayName)
                        .font(.title2.weight(.semibold))
                    Text(appTagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                headerStatusPane
                summaryPane
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var headerStatusPane: some View {
        HStack(alignment: .center, spacing: 8) {
            if model.isBusy || model.isCalendarLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var primaryActionsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Actions")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    manageSourcesPane(layout: .singleRow)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    runSyncPane(layout: .singleRow)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                HStack(alignment: .top, spacing: 12) {
                    manageSourcesPane(layout: .pairedRows)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    runSyncPane(layout: .pairedRows)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 10) {
                    manageSourcesPane(layout: .singleColumn)
                    Divider()
                    runSyncPane(layout: .singleColumn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    @ViewBuilder
    private func manageSourcesPane(layout: QuickActionLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manage Sources")
                .font(.subheadline.weight(.semibold))
            switch layout {
            case .singleRow:
                HStack(spacing: 8) {
                    newSourceButton
                    saveSourceButton
                    removeSourceButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .pairedRows:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        newSourceButton
                        saveSourceButton
                    }
                    HStack(spacing: 8) {
                        removeSourceButton
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .singleColumn:
                VStack(alignment: .leading, spacing: 8) {
                    newSourceButton
                    saveSourceButton
                    removeSourceButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func runSyncPane(layout: QuickActionLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run Sync")
                .font(.subheadline.weight(.semibold))
            switch layout {
            case .singleRow:
                HStack(spacing: 8) {
                    previewButton
                    syncButton
                    approveAIButton
                    openCalendarButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .pairedRows:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        previewButton
                        syncButton
                    }
                    HStack(spacing: 8) {
                        approveAIButton
                        openCalendarButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .singleColumn:
                VStack(alignment: .leading, spacing: 8) {
                    previewButton
                    syncButton
                    approveAIButton
                    openCalendarButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.pendingAIReviews.isEmpty {
                Text("\(model.pendingAIReviews.count) source(s) need AI approval before low-confidence sync can run.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }

    private var newSourceButton: some View {
        Button {
            clearInputFocus()
            model.newSource()
        } label: {
            Label("New", systemImage: "plus")
        }
        .buttonStyle(.bordered)
    }

    private var saveSourceButton: some View {
        Button {
            clearInputFocus()
            model.saveCurrentSource()
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
    }

    private var removeSourceButton: some View {
        Button(role: .destructive) {
            clearInputFocus()
            model.removeSelectedSource()
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(model.selectedSourceID == nil)
    }

    private var previewButton: some View {
        Button {
            clearInputFocus()
            model.previewAll()
        } label: {
            Label("Preview", systemImage: "eye")
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
    }

    private var syncButton: some View {
        Button {
            clearInputFocus()
            model.syncAll()
        } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isBusy)
    }

    private var openCalendarButton: some View {
        Button {
            clearInputFocus()
            model.openCalendarApp()
        } label: {
            Label("Calendar", systemImage: "calendar")
        }
        .buttonStyle(.bordered)
    }

    private var approveAIButton: some View {
        Button {
            clearInputFocus()
            model.approvePendingAIReviews()
        } label: {
            Label("Approve AI", systemImage: "checkmark.shield")
        }
        .buttonStyle(.bordered)
        .disabled(model.pendingAIReviews.isEmpty || model.isBusy)
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.headline)
            Group {
                if model.output.isEmpty, let placeholder = activityPlaceholder {
                    VStack(spacing: 10) {
                        Image(systemName: placeholder.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(placeholder.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(placeholder.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(16)
                } else {
                    ScrollView(.vertical) {
                        Text(model.output.isEmpty ? "No activity yet." : model.output)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.sources) { item in
                        Button {
                            clearInputFocus()
                            model.selectSource(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    sourceStatusIcon(for: item)
                                    Text(item.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    if !item.enabled {
                                        Text("Off")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule()
                                                    .fill(Color.secondary.opacity(0.12))
                                            )
                                    }
                                }
                                Text(sourceStatusSummary(for: item))
                                    .font(.caption)
                                    .foregroundStyle(sourceStatusColor(for: item))
                                    .lineLimit(1)
                                Text("\(item.bookingID) -> \(item.calendar)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(model.selectedSourceID == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(sourceStatusHelp(for: item))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: sourceListHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceDetailsPane
            aiParsingPane
            defaultHoursPane
            automationPane
        }
    }

    @ViewBuilder
    private var bookingFields: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                bookingIDField
                eventTitleField
            }

            VStack(alignment: .leading, spacing: 10) {
                bookingIDField
                eventTitleField
            }
        }
    }

    private var sourceFieldRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                sourceFieldInput
                browseSourceButton
            }

            VStack(alignment: .leading, spacing: 8) {
                sourceFieldInput
                browseSourceButton
            }
        }
    }

    private var defaultHoursPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(
                title: "Default Work Hours",
                subtitle: "Used only when a sheet shows dates without specific times. If the sheet already includes exact times, those times win automatically."
            )

            WorkdayHoursEditor(start: deferredBinding(\.workdayStart), end: deferredBinding(\.workdayEnd))
                .onChange(of: model.workdayStart) { _ in
                    model.workdayChanged()
                }
                .onChange(of: model.workdayEnd) { _ in
                    model.workdayChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    fileprivate var sourceDetailsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    PaneHeader(
                        title: "Source Details",
                        subtitle: "Saved sheet sources can stay in the list without participating in sync. Dropped images are treated as one-time imports and do not replace the saved source."
                    )
                    Spacer(minLength: 8)
                    sourceEnabledToggle
                }

                VStack(alignment: .leading, spacing: 8) {
                    PaneHeader(
                        title: "Source Details",
                        subtitle: "Saved sheet sources can stay in the list without participating in sync. Dropped images are treated as one-time imports and do not replace the saved source."
                    )
                    sourceEnabledToggle
                }
            }
            
            FieldLabel(title: "Source")
            sourceFieldRow

            SourceDropZone { urls in
                model.handleDroppedSourceFiles(urls)
            }

            bookingFields

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 10) {
                    calendarPicker
                    if model.calendarAccessState != .granted {
                        Button(model.calendarAccessState.promptButtonTitle) {
                            clearInputFocus()
                            model.requestCalendarAccess()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Refresh Calendars") {
                        clearInputFocus()
                        model.refreshCalendars()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 10) {
                    calendarPicker
                    HStack(spacing: 10) {
                        if model.calendarAccessState != .granted {
                            Button(model.calendarAccessState.promptButtonTitle) {
                                clearInputFocus()
                                model.requestCalendarAccess()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Refresh Calendars") {
                            clearInputFocus()
                            model.refreshCalendars()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var aiParsingPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(
                title: "AI Parsing",
                subtitle: "For most customers, setup is just: choose a supported AI platform, paste the API key, and let the app fill the endpoint and default model."
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    FieldLabel(title: "Parser Mode")
                    Text("(\(model.parserMode.inlineSummary))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("", selection: deferredBinding(\.parserMode)) {
                    ForEach(ParserMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: model.parserMode) { _ in
                    model.parserSettingsChanged()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "AI Platform")
                HStack(spacing: 10) {
                    Picker("", selection: deferredBinding(\.aiProvider)) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.pickerTitle).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 180, maxWidth: 280, alignment: .leading)
                    .onChange(of: model.aiProvider) { _ in
                        model.aiProviderChanged()
                    }
                    Spacer(minLength: 0)
                }
                Text(model.aiProvider.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "API Key")
                SecureField("Stored in macOS Keychain", text: deferredBinding(\.aiAPIKey))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onChange(of: model.aiAPIKey) { _ in
                        model.parserSettingsChanged()
                    }
            }

            DisclosureGroup(isExpanded: deferredBinding(\.showAdvancedAISettings)) {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            aiEndpointField
                            aiModelField
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            aiEndpointField
                            aiModelField
                        }
                    }
                    Text("Supported platforms auto-fill the endpoint and default model. Custom mode keeps the endpoint editable for providers or gateways outside the preset list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Leave Model Override blank to use the app's recommended model automatically. Image sources may use a different built-in model than sheet sources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                Text("Advanced AI Settings")
                    .font(.subheadline.weight(.medium))
            }

            Text("Approved AI layouts stored: \(model.aiApprovals.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var automationPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(
                title: "Automation",
                subtitle: "Polling only runs while the app stays open. Closed apps do not sync."
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    automationToggles
                    automationIntervalField
                }

                VStack(alignment: .leading, spacing: 10) {
                    automationToggles
                    automationIntervalField
                }
            }
            Text("The app can add, update, and remove previously synced events when the source changes. You can confirm every sync, or only ask before deletions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var bookingIDField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Booking ID")
            TextField("LJZ", text: deferredBinding(\.draftBookingID))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.draftBookingID) { _ in
                    model.draftFieldsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eventTitleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Event Title")
            TextField("ppms", text: deferredBinding(\.draftName))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.draftName) { _ in
                    model.draftFieldsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calendarPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Calendar")
            Picker("", selection: deferredBinding(\.draftCalendar)) {
                ForEach(calendarChoices, id: \.self) { calendar in
                    Text(calendar).tag(calendar)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: model.draftCalendar) { _ in
                model.draftFieldsChanged()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceFieldInput: some View {
        TextField("Google Sheets link, local .xlsx workbook, or image path", text: deferredBinding(\.draftSource))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: model.draftSource) { _ in
                model.draftFieldsChanged()
            }
    }

    private var browseSourceButton: some View {
        Button("Browse") {
            clearInputFocus()
            model.chooseSourceFile()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minWidth: 88)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sourceEnabledToggle: some View {
        Toggle("Use in sync", isOn: deferredBinding(\.draftEnabled))
            .toggleStyle(.checkbox)
            .fixedSize()
            .controlSize(.small)
            .help("When off, this source stays saved but is skipped during preview and sync.")
            .onChange(of: model.draftEnabled) { _ in
                model.draftFieldsChanged()
            }
    }

    private var aiEndpointField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "API Endpoint")
            TextField(model.aiProvider.defaultEndpointURL.isEmpty ? "Enter provider endpoint" : model.aiProvider.defaultEndpointURL, text: deferredBinding(\.aiEndpointURL))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.aiEndpointURL) { _ in
                    model.parserSettingsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiModelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: "Model Override")
            TextField(model.aiProvider == .custom ? "Enter model name" : "Auto (\(model.aiProvider.automaticModelSummary))", text: deferredBinding(\.aiModel))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: model.aiModel) { _ in
                    model.parserSettingsChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var automationToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Only future reservations", isOn: deferredBinding(\.upcomingOnly))
                .onChange(of: model.upcomingOnly) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Auto sync while the app is open", isOn: deferredBinding(\.autoSyncEnabled))
                .onChange(of: model.autoSyncEnabled) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Show confirmation before sync", isOn: deferredBinding(\.confirmBeforeSync))
                .onChange(of: model.confirmBeforeSync) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Ask before deleting removed events", isOn: deferredBinding(\.confirmBeforeDeletion))
                .onChange(of: model.confirmBeforeDeletion) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Keep running in menu bar", isOn: deferredBinding(\.menuBarModeEnabled))
                .onChange(of: model.menuBarModeEnabled) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
        }
    }

    private var automationIntervalField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title: "Interval (minutes)")
            TextField("15", text: deferredBinding(\.autoSyncMinutes))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 92, idealWidth: 110, maxWidth: 140, alignment: .leading)
                .controlSize(.small)
                .onSubmit {
                    model.automationChanged()
                }
                .onChange(of: model.autoSyncMinutes) { _ in
                    model.automationChanged()
                }
        }
    }

    private var calendarChoices: [String] {
        var values = model.calendars
        let current = model.draftCalendar.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !values.contains(current) {
            values.insert(current, at: 0)
        }
        return values
    }

    private var sourceListHeight: CGFloat {
        let rowCount = max(model.sources.count, 1)
        let estimatedHeight = CGFloat(rowCount) * 60 + 18
        return min(max(estimatedHeight, 108), 220)
    }

    @ViewBuilder
    private func sourceStatusIcon(for item: SourceItem) -> some View {
        switch model.runtimeStatus(for: item) {
        case .idle:
            Image(systemName: item.enabled ? "circle" : "pause.circle")
                .foregroundStyle(item.enabled ? Color.secondary : Color.secondary.opacity(0.8))
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .review:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failure:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func sourceStatusSummary(for item: SourceItem) -> String {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return item.enabled ? "Ready to read" : "Saved but skipped"
        case .loading:
            return "Reading sheet..."
        case .success(let matchCount):
            let noun = matchCount == 1 ? "match" : "matches"
            return "Read OK · \(matchCount) \(noun)"
        case .review(let matchCount):
            let noun = matchCount == 1 ? "match" : "matches"
            return "Review needed · \(matchCount) \(noun)"
        case .failure:
            return "Read failed"
        }
    }

    private func sourceStatusHelp(for item: SourceItem) -> String {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return item.enabled ? "This source is enabled and ready for preview or sync." : "This source is saved but currently skipped during preview and sync."
        case .loading:
            return "The app is downloading or parsing this source now."
        case .success(let matchCount):
            let noun = matchCount == 1 ? "reservation" : "reservations"
            return "The last read succeeded and found \(matchCount) matching \(noun)."
        case .review(let matchCount):
            let noun = matchCount == 1 ? "reservation" : "reservations"
            return "The source was parsed, but the AI confidence is too low for unattended sync. Preview and approve this layout before syncing. Current preview found \(matchCount) matching \(noun)."
        case .failure(let message):
            return message
        }
    }

    private func sourceStatusColor(for item: SourceItem) -> Color {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return .secondary
        case .loading:
            return .secondary
        case .success:
            return .green
        case .review:
            return .orange
        case .failure:
            return .red
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appDisplayName)
                .font(.headline)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("Show Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)

            Button("Preview Now") {
                model.previewAll()
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)

            Button("Sync Now") {
                model.syncAll()
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)

            Button("Open Calendar") {
                model.openCalendarApp()
            }
            .buttonStyle(.plain)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }
}

#if PPMS_TEST_RUNNER
import AppKit

@MainActor
private func writeSnapshot(to outputURL: URL, width: CGFloat, height: CGFloat) throws {
    let detailsOnly = ProcessInfo.processInfo.environment["PPMS_SNAPSHOT_DETAILS_ONLY"] == "1"
    let sourceDetailsOnly = ProcessInfo.processInfo.environment["PPMS_SNAPSHOT_SOURCE_DETAILS_ONLY"] == "1"
    let sidebarOnly = ProcessInfo.processInfo.environment["PPMS_SNAPSHOT_SIDEBAR_ONLY"] == "1"
    let model = AppModel()
    let base = ContentView()
    let content = Group {
        if sidebarOnly {
            base.sidebarPane
                .environmentObject(model)
                .padding(16)
        } else if sourceDetailsOnly {
            base.sourceDetailsPane
                .environmentObject(model)
                .padding(16)
        } else if detailsOnly {
            base.detailColumn
                .environmentObject(model)
                .padding(16)
        } else {
            base.environmentObject(model)
        }
    }
    .frame(width: width, height: height)
    .background(Color.white)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2

    guard let cgImage = renderer.cgImage else {
        throw AppFailure.syncFailed("Failed to render UI snapshot.")
    }

    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
        throw AppFailure.syncFailed("Failed to encode UI snapshot as PNG.")
    }

    try pngData.write(to: outputURL)
}

@main
struct PPMSCalendarSyncTestRunner {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        if let outputPath = environment["PPMS_SNAPSHOT_OUTPUT"] {
            let width = Double(environment["PPMS_SNAPSHOT_WIDTH"] ?? "") ?? 980
            let height = Double(environment["PPMS_SNAPSHOT_HEIGHT"] ?? "") ?? 900

            do {
                try await MainActor.run {
                    try writeSnapshot(
                        to: URL(fileURLWithPath: outputPath),
                        width: width,
                        height: height
                    )
                }
                print("Wrote snapshot: \(outputPath)")
                return
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        let source = SourceItem(
            name: environment["PPMS_TEST_SOURCE_NAME"] ?? "ppms",
            source: environment["PPMS_TEST_SOURCE_URL"] ?? "https://docs.google.com/spreadsheets/d/1J7XCLh20n1qBkhBNyfF0XwnM2vItuOlGl6j5iQR1aVg/edit?usp=sharing",
            bookingID: environment["PPMS_TEST_BOOKING_ID"] ?? "LJZ",
            calendar: environment["PPMS_TEST_CALENDAR"] ?? "Experiment"
        )
        let parserMode = ParserMode(rawValue: environment["PPMS_TEST_PARSER_MODE"] ?? "") ?? .rulesOnly
        let aiProvider = AIProvider(rawValue: environment["PPMS_TEST_AI_PROVIDER"] ?? "")
            ?? inferAIProvider(fromEndpoint: environment["PPMS_TEST_AI_ENDPOINT"] ?? "")
        let aiConfiguration: AIServiceConfiguration? = {
            guard
                let endpoint = environment["PPMS_TEST_AI_ENDPOINT"],
                let apiKey = environment["PPMS_TEST_AI_KEY"],
                let url = URL(string: endpoint)
            else {
                return nil
            }
            let model = environment["PPMS_TEST_AI_MODEL"] ?? ""
            if aiProvider == .custom && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            return AIServiceConfiguration(provider: aiProvider, endpointURL: url, apiKey: apiKey, model: model)
        }()
        do {
            let result = try await ReservationExtractor.extract(
                source: source,
                workdayHours: defaultWorkdayHours(),
                upcomingOnly: false,
                parserMode: parserMode,
                aiConfiguration: aiConfiguration
            )
            print("All matched reservations: \(result.allEvents.count)")
            print("Parser: \(result.parserLabel)")
            print("Review required: \(result.reviewRequired)")
            for event in result.allEvents {
                let prefix = event.isAllDay ? "all-day" : "timed"
                print("\(prefix)\t\(iso8601(event.start))\t\(iso8601(event.end))\t\(event.sourceName)")
            }
            let preview = try await CalendarSyncEngine().sync(
                sources: [source],
                workdayHours: defaultWorkdayHours(),
                upcomingOnly: true,
                previewOnly: true,
                parserMode: parserMode,
                aiConfiguration: aiConfiguration,
                aiApprovals: []
            )
            print("")
            print("Preview output:")
            print(preview.outputText)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            let details = String(describing: error)
            if details != error.localizedDescription {
                fputs("\(details)\n", stderr)
            }
            Foundation.exit(1)
        }
    }
}
#else
private func applyAppPresentation(menuBarModeEnabled: Bool) {
    NSApp.setActivationPolicy(menuBarModeEnabled ? .accessory : .regular)
}

@main
struct PPMSCalendarSyncApp: App {
    @StateObject private var model = AppModel()
    @State private var menuBarExtraInserted = false

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    syncAppPresentation(to: model.menuBarModeEnabled)
                }
                .onChange(of: model.menuBarModeEnabled) { enabled in
                    syncAppPresentation(to: enabled)
                }
        }
        .defaultSize(width: 1180, height: 900)

        MenuBarExtra(appDisplayName, systemImage: "calendar.badge.clock", isInserted: $menuBarExtraInserted) {
            MenuBarContentView()
                .environmentObject(model)
        }
    }

    private func syncAppPresentation(to enabled: Bool) {
        if menuBarExtraInserted != enabled {
            menuBarExtraInserted = enabled
        }
        applyAppPresentation(menuBarModeEnabled: enabled)
    }
}
#endif
