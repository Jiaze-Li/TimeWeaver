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

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        name: String,
        source: String,
        bookingID: String,
        calendar: String
    ) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.source = source
        self.bookingID = bookingID
        self.calendar = calendar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.name = try container.decode(String.self, forKey: .name)
        self.source = try container.decode(String.self, forKey: .source)
        self.bookingID = try container.decode(String.self, forKey: .bookingID)
        self.calendar = try container.decode(String.self, forKey: .calendar)
    }
}

extension SourceItem {
    var stableIdentity: String {
        id.uuidString
    }

    var legacyIdentity: String {
        TimeWeaverCore.fnv1a64Hex("\(name)|\(source)|\(bookingID)|\(calendar)")
    }
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
