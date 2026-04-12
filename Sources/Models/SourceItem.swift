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

typealias SlotRule = TimeWeaverCore.SlotRule

struct WorkdayHours: Codable, Equatable {
    var start: String
    var end: String
}
