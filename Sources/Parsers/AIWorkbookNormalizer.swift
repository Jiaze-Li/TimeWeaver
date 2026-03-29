import Foundation

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

struct AINormalizationResult {
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

struct AIWorkbookNormalizer {
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
        Use two independent matching paths and cross-validate: (1) color path — find the booking ID in the legend, sample its color, locate all cells of that color; (2) text path — scan the entire image for any cell or label that directly contains the booking ID text. In your explanation for each occurrence, note which path(s) confirmed it and assign higher confidence when both agree.
        If the booking ID contains Chinese characters, also match entries where the name appears with or without common honorifics (老师, 先生, 女士, 同学) or abbreviated to surname only.
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw classifyAITransportError(error)
        }
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw classifyAIHTTPError(statusCode: httpResponse.statusCode, responseData: data)
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw classifyAITransportError(error)
        }
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw classifyAIHTTPError(statusCode: httpResponse.statusCode, responseData: data)
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw classifyAITransportError(error)
        }
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw classifyAIHTTPError(statusCode: httpResponse.statusCode, responseData: data)
        }
        return data
    }

    private static func classifyAITransportError(_ error: Error) -> AppFailure {
        guard let urlError = error as? URLError else {
            return .syncFailed("AI parser request failed: \(error.localizedDescription)")
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .syncFailed("AI parser request failed: network connection error (\(urlError.localizedDescription)).")
        case .timedOut:
            return .syncFailed("AI parser request failed: request timed out. Check network and endpoint latency.")
        case .userAuthenticationRequired:
            return .syncFailed("AI parser request failed: authentication is required by the endpoint.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return .syncFailed("AI parser request failed: TLS/SSL validation error. Check certificate configuration.")
        default:
            return .syncFailed("AI parser request failed: \(urlError.localizedDescription)")
        }
    }

    private static func classifyAIHTTPError(statusCode: Int, responseData: Data) -> AppFailure {
        let body = String(data: responseData, encoding: .utf8) ?? ""
        let bodyLower = body.lowercased()

        if statusCode == 401 || statusCode == 403 {
            return .syncFailed("AI parser request failed: API key is invalid or lacks permission (HTTP \(statusCode)).")
        }
        if statusCode == 429 {
            return .syncFailed("AI parser request failed: rate limited by provider (HTTP 429).")
        }
        if bodyLower.contains("refus") || bodyLower.contains("safety") || bodyLower.contains("policy") || bodyLower.contains("blocked") {
            return .syncFailed("AI parser request failed: model refused the request due to policy/safety constraints (HTTP \(statusCode)).")
        }
        if bodyLower.contains("model") && (bodyLower.contains("not found") || bodyLower.contains("does not exist") || bodyLower.contains("invalid")) {
            return .syncFailed("AI parser request failed: model name is invalid or unavailable (HTTP \(statusCode)).")
        }
        let summary = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        if summary.isEmpty {
            return .syncFailed("AI parser request failed with HTTP \(statusCode).")
        }
        return .syncFailed("AI parser request failed with HTTP \(statusCode): \(summary)")
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

