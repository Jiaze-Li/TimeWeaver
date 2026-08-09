import Foundation

struct AIImageAttachment {
    var data: Data
    var mimeType: String
}

extension AIWorkbookNormalizer {
    static func localOCRHints(from imageURL: URL) -> String? {
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

    static func refineImageNormalization(
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

        let requestResponse = try await requestPayload(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: attachment
        )
        let result = try buildNormalizationResult(
            payloadData: requestResponse.payloadData,
            workbookFingerprint: workbookFingerprint,
            workdayHours: workdayHours,
            timeZone: timeZone
        )
        return noteProviderUsage(
            for: result,
            primaryProvider: configuration.provider,
            providerUsed: requestResponse.providerUsed,
            usedFallback: requestResponse.usedFallback
        )
    }

    static func preferredImageNormalization(
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

    static func applyImageProviderPolicy(
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
        case .anthropic:
            policyNote = "Anthropic image parsing should be reviewed before syncing."
        case .openAI, .openRouter, .custom:
            policyNote = "\(provider.title) image parsing should be reviewed before syncing. Gemini or Anthropic is recommended for uploaded timetable images."
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

    static func imageExtractionStyle(for provider: AIProvider) -> ImageExtractionStyle {
        switch provider {
        case .gemini, .anthropic:
            return .directTimestamps
        case .openAI, .kimi, .openRouter, .custom, .deepSeek:
            return .visibleFields
        }
    }

    static func imageSchema(for extractionStyle: ImageExtractionStyle) -> [String: Any] {
        switch extractionStyle {
        case .directTimestamps:
            return timestampNormalizationSchema()
        case .visibleFields:
            return imageNormalizationSchema()
        }
    }

    static func imageInstructions(for extractionStyle: ImageExtractionStyle) -> String {
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

    static func verificationInstructions(for extractionStyle: ImageExtractionStyle) -> String {
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

    static func imageNormalizationSchema() -> [String: Any] {
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

    static func timestampNormalizationSchema() -> [String: Any] {
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

    static func makeImageAttachment(from imageURL: URL) throws -> AIImageAttachment? {
        guard let mimeType = imageMimeType(for: imageURL) else {
            return nil
        }
        let data = try Data(contentsOf: imageURL)
        return AIImageAttachment(data: data, mimeType: mimeType)
    }
}
