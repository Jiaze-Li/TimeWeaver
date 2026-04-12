import Foundation

protocol AIWorkbookNormalizerProtocol {
    func normalize(
        source: SourceItem,
        workdayHours: WorkdayHours,
        sheets: [ParsedWorkbookSheet],
        configuration: AIServiceConfiguration,
        timeZone: TimeZone
    ) async throws -> AINormalizationResult

    func normalizeImage(
        source: SourceItem,
        workdayHours: WorkdayHours,
        imageURL: URL,
        configuration: AIServiceConfiguration,
        timeZone: TimeZone
    ) async throws -> AINormalizationResult
}

protocol LocalImageParserProtocol {
    func parse(
        source: SourceItem,
        workdayHours: WorkdayHours,
        imageURL: URL,
        timeZone: TimeZone
    ) throws -> LocalTimetableParseResult?
}

struct DefaultAIWorkbookNormalizer: AIWorkbookNormalizerProtocol {
    func normalize(
        source: SourceItem,
        workdayHours: WorkdayHours,
        sheets: [ParsedWorkbookSheet],
        configuration: AIServiceConfiguration,
        timeZone: TimeZone
    ) async throws -> AINormalizationResult {
        try await AIWorkbookNormalizer.normalize(
            source: source,
            workdayHours: workdayHours,
            sheets: sheets,
            configuration: configuration,
            timeZone: timeZone
        )
    }

    func normalizeImage(
        source: SourceItem,
        workdayHours: WorkdayHours,
        imageURL: URL,
        configuration: AIServiceConfiguration,
        timeZone: TimeZone
    ) async throws -> AINormalizationResult {
        try await AIWorkbookNormalizer.normalizeImage(
            source: source,
            workdayHours: workdayHours,
            imageURL: imageURL,
            configuration: configuration,
            timeZone: timeZone
        )
    }
}

struct DefaultLocalImageParser: LocalImageParserProtocol {
    func parse(
        source: SourceItem,
        workdayHours: WorkdayHours,
        imageURL: URL,
        timeZone: TimeZone
    ) throws -> LocalTimetableParseResult? {
        try LocalTimetableImageParser.parse(
            source: source,
            workdayHours: workdayHours,
            imageURL: imageURL,
            timeZone: timeZone
        )
    }
}
