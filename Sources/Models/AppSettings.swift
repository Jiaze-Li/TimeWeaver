import Foundation

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
    var schedulingTimeZoneIdentifier: String
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
        case schedulingTimeZoneIdentifier
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
        schedulingTimeZoneIdentifier: String,
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
        self.schedulingTimeZoneIdentifier = schedulingTimeZoneIdentifier
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
        self.schedulingTimeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .schedulingTimeZoneIdentifier)
            ?? defaultSchedulingTimeZoneIdentifier
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
        try container.encode(schedulingTimeZoneIdentifier, forKey: .schedulingTimeZoneIdentifier)
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

