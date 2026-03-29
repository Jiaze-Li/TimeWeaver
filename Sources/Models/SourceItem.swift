import Foundation

struct SourceItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String
    var source: String
    var bookingID: String
    var calendar: String
}

struct SlotRule: Codable, Equatable {
    var sheetLabel: String
    var start: String
    var end: String
    var endsNextDay: Bool
}

struct WorkdayHours: Codable, Equatable {
    var start: String
    var end: String
}
