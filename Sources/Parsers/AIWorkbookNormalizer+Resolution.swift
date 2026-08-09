import Foundation

struct AINormalizationResult {
    var occurrences: [SlotOccurrence]
    var notes: [String]
    var workbookFingerprint: String
    var averageConfidence: Double?
    var minimumConfidence: Double?
    var reviewRequired: Bool
}

private struct AINormalizationPayload {
    var parserSummary: String
    var occurrences: [AINormalizedOccurrence]
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

extension AIWorkbookNormalizer {
    static func buildNormalizationResult(
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

    static func parseVisibleDate(_ rawText: String?, timeZone: TimeZone) -> (date: Date, requiresReview: Bool)? {
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
            regex: visibleDateWithYearRegex
        ),
           let year = Int(components[0]),
           let month = Int(components[1]),
           let day = Int(components[2]),
           let date = makeVisibleDate(year: year, month: month, day: day, timeZone: timeZone) {
            return (date, false)
        }

        if let components = firstMatch(
            in: normalized,
            regex: visibleDateWithoutYearRegex
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

    static func parseVisibleTimeRange(
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

    static func normalizeVisibleClock(_ rawText: String?) -> String? {
        guard let rawText else { return nil }
        guard let match = firstMatch(
            in: rawText.replacingOccurrences(of: "：", with: ":"),
            regex: visibleClockRegex
        ) else {
            return nil
        }
        guard let hour = Int(match[0]), let minute = Int(match[1]), (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    static func extractVisibleClocks(from rawText: String) -> [String] {
        let normalized = rawText.replacingOccurrences(of: "：", with: ":")
        let nsRange = NSRange(normalized.startIndex..., in: normalized)
        return visibleClockRegex.matches(in: normalized, range: nsRange).compactMap { match in
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

    static func firstMatch(in source: String, regex: NSRegularExpression) -> [String]? {
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

    static func makeVisibleDate(year: Int, month: Int, day: Int, timeZone: TimeZone) -> Date? {
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

    static func chronologicalAnomalyNote(for occurrences: [SlotOccurrence]) -> String? {
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
}
