import Foundation

struct AIWorkbookNormalizer {
    enum ImageExtractionStyle {
        case directTimestamps
        case visibleFields
    }

    struct AIRequestPayloadResponse {
        var payloadData: Data
        var providerUsed: AIProvider
        var usedFallback: Bool
    }

    struct CachedAINormalizationResult {
        var result: AINormalizationResult
        var expiresAt: Date
    }

    static let normalizationCacheTTL: TimeInterval = 30 * 60
    static var normalizationCache: [String: CachedAINormalizationResult] = [:]
    static let normalizationCacheLock = NSLock()
    static let visibleClockRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2}):(\d{2})(?!\d)"#)
    static let visibleDateWithYearRegex = try! NSRegularExpression(pattern: #"(?<!\d)(20\d{2})\D{0,3}(\d{1,2})\D{0,3}(\d{1,2})(?!\d)"#)
    static let visibleDateWithoutYearRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\D{0,3}(\d{1,2})(?!\d)"#)

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
        let cacheKey = workbookFingerprint + "|" + configuration.provider.rawValue + "|" + configuration.model
        if let cached = cachedNormalizationResult(for: cacheKey) {
            return addingNote("Using cached AI result.", to: cached)
        }
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
        Use two independent matching paths and cross-validate: (1) color path — find the booking ID in the legend, sample its color, locate all cells of that color; (2) text path — scan the entire image for any cell or label that directly contains the booking ID text. In your explanation for each occurrence, note which path(s) confirmed it and assign higher confidence when both agree.
        If the booking ID contains Chinese characters, also match entries where the name appears with or without common honorifics (老师, 先生, 女士, 同学) or abbreviated to surname only.
        \(ocrHints.map { "\nLocal OCR hints (secondary check only; trust the image if OCR conflicts):\n\($0)" } ?? "")
        """

        let schema = imageSchema(for: extractionStyle)

        let requestResponse = try await requestPayload(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: attachment
        )

        let initialResult = try buildNormalizationResult(
            payloadData: requestResponse.payloadData,
            workbookFingerprint: workbookFingerprint,
            workdayHours: workdayHours,
            timeZone: timeZone
        )
        let initial = noteProviderUsage(
            for: initialResult,
            primaryProvider: configuration.provider,
            providerUsed: requestResponse.providerUsed,
            usedFallback: requestResponse.usedFallback
        )
        guard configuration.provider != .gemini, configuration.provider != .kimi, configuration.provider != .anthropic, !initial.occurrences.isEmpty else {
            let finalized = applyImageProviderPolicy(to: initial, provider: configuration.provider)
            cacheNormalizationResult(finalized, for: cacheKey)
            return finalized
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
        let finalized = applyImageProviderPolicy(to: preferred, provider: configuration.provider)
        cacheNormalizationResult(finalized, for: cacheKey)
        return finalized
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
        let cacheKey = workbookFingerprint + "|" + configuration.provider.rawValue + "|" + configuration.model
        if let cached = cachedNormalizationResult(for: cacheKey) {
            return addingNote("Using cached AI result.", to: cached)
        }

        let instructions = """
        You normalize reservation spreadsheets into atomic calendar occurrences.
        Match only reservations that belong to the provided booking ID.
        The booking ID field may list several IDs separated by commas. Treat them as alternatives: include any cell that matches ANY one of the listed IDs.
        Return one occurrence per directly observed occupied slot or day. Do not pre-merge adjacent matches.
        Use the supplied timezone for all timestamps.
        If the workbook only gives a date without explicit times, use the provided default workday start and end for that day and set all_day to false.
        If the workbook uses timed slots, use explicit times from the workbook whenever they are visible in the sheet.
        Do not invent bookings when the match is ambiguous. Return an empty occurrences array if nothing confidently matches.
        If the booking ID contains Chinese characters, also match entries where the name includes or omits common honorifics (老师, 先生, 女士, 同学) or is abbreviated to surname only.
        Where possible, cross-validate matches found via color/legend mapping against direct text occurrences of the booking ID; prefer occurrences confirmed by both methods.
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

        let requestResponse = try await requestPayload(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema
        )
        let result = try buildNormalizationResult(
            payloadData: requestResponse.payloadData,
            workbookFingerprint: workbookFingerprint,
            workdayHours: workdayHours,
            timeZone: timeZone
        )
        let noted = noteProviderUsage(
            for: result,
            primaryProvider: configuration.provider,
            providerUsed: requestResponse.providerUsed,
            usedFallback: requestResponse.usedFallback
        )
        cacheNormalizationResult(noted, for: cacheKey)
        return noted
    }
}
