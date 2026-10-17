import Foundation

public enum TimeWeaverCore {
    public enum AutoParserStrategy: Equatable {
        case ruleBased
        case ruleBasedNoAIConfiguration
        case aiNormalization
    }

    public enum UpsertMutation: Equatable {
        case create
        case update
        case unchanged
    }

    public static func chooseAutoParserStrategy(
        ruleOccurrencesCount: Int,
        hasAIConfiguration: Bool
    ) -> AutoParserStrategy {
        if ruleOccurrencesCount > 0 {
            return .ruleBased
        }
        return hasAIConfiguration ? .aiNormalization : .ruleBasedNoAIConfiguration
    }

    public static func determineUpsertMutation(
        hasExistingEvent: Bool,
        oldSignature: String,
        newSignature: String
    ) -> UpsertMutation {
        if !hasExistingEvent {
            return .create
        }
        return oldSignature == newSignature ? .unchanged : .update
    }

    public static func matchesSourceIdentity(
        trackedSourceID: String,
        currentSourceID: String,
        legacySourceID: String? = nil
    ) -> Bool {
        if trackedSourceID == currentSourceID {
            return true
        }
        if let legacySourceID, !legacySourceID.isEmpty, trackedSourceID == legacySourceID {
            return true
        }
        return false
    }

    public static func isDeletionSuspicious(
        trackedCount: Int,
        extractedCount: Int,
        reviewRequired: Bool
    ) -> Bool {
        if reviewRequired && trackedCount > 0 {
            return true
        }
        if trackedCount > 0 && extractedCount == 0 {
            return true
        }
        return false
    }

    public static func validateTimeInterval(start: Date, end: Date) -> Bool {
        start < end
    }

    public static func shouldDeleteTrackedEvent(
        trackedSourceID: String,
        requestedSourceID: String,
        legacySourceID: String? = nil,
        syncKey: String,
        activeSyncKeys: Set<String>,
        trackedStartISO: String,
        upcomingOnly: Bool,
        now: Date,
        timeZone: TimeZone
    ) -> Bool {
        guard matchesSourceIdentity(trackedSourceID: trackedSourceID, currentSourceID: requestedSourceID, legacySourceID: legacySourceID) else {
            return false
        }
        guard !activeSyncKeys.contains(syncKey) else {
            return false
        }
        if !upcomingOnly {
            return true
        }
        guard let start = parseISO8601(trackedStartISO, timeZone: timeZone) else {
            return false
        }
        return start >= now
    }

    public static func fnv1a64Hex(_ text: String) -> String {
        let hash = Data(text.utf8).reduce(into: UInt64(1469598103934665603)) { value, byte in
            value = (value ^ UInt64(byte)) &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Slot Rule Parsing

    public struct SlotRule: Codable, Equatable {
        public var sheetLabel: String
        public var start: String
        public var end: String
        public var endsNextDay: Bool

        public init(sheetLabel: String, start: String, end: String, endsNextDay: Bool) {
            self.sheetLabel = sheetLabel
            self.start = start
            self.end = end
            self.endsNextDay = endsNextDay
        }
    }

    public static func inferredSlotRule(from label: String, builtinRules: [SlotRule]) -> SlotRule? {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        if let builtin = builtinRules.first(where: {
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

    public static func parseSlotRange(from label: String) -> (start: String, end: String, endsNextDay: Bool)? {
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
            start: slotClockString(fromMinutes: best.start),
            end: slotClockString(fromMinutes: best.end),
            endsNextDay: best.end <= best.start
        )
    }

    private static func resolvedTimeCandidates(from token: String) -> [Int]? {
        let pattern = #"^(\d{1,2})(?::(\d{2}))?([ap]m)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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

    private static func slotClockString(fromMinutes minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - ISO8601 Parsing

    private static func parseISO8601(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        if let value = formatter.date(from: text) {
            return value
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
