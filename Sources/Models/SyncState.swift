import Foundation

struct StoredEvent: Codable {
    var eventIdentifier: String
    var sourceID: String
    var calendar: String
    var title: String
    var startISO: String
    var endISO: String
}

struct SyncState: Codable {
    var events: [String: StoredEvent]
}
