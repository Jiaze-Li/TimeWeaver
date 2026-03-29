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

    public static func shouldDeleteTrackedEvent(
        trackedSourceID: String,
        requestedSourceID: String,
        syncKey: String,
        activeSyncKeys: Set<String>,
        trackedStartISO: String,
        upcomingOnly: Bool,
        now: Date,
        timeZone: TimeZone
    ) -> Bool {
        guard trackedSourceID == requestedSourceID else {
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
