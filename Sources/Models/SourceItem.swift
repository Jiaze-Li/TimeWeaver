import Foundation
#if canImport(TimeWeaverCore)
import TimeWeaverCore
#endif

struct SourceItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String
    var source: String
    var bookingID: String
    var calendar: String
}

extension SourceItem {
    /// The individual booking IDs to match, parsed from the comma-separated `bookingID` field.
    /// A single ID (no comma) yields a one-element list, preserving legacy behavior.
    var bookingIDs: [String] {
        bookingID
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Returns true when `value` exactly matches any configured booking ID (case-insensitive).
    /// For a single configured ID this is identical to the previous direct comparison.
    func matchesBookingID(_ value: String) -> Bool {
        bookingIDs.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }
}

typealias SlotRule = TimeWeaverCore.SlotRule

struct WorkdayHours: Codable, Equatable {
    var start: String
    var end: String
}
