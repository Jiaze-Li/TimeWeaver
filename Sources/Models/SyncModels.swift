import Foundation
import EventKit

struct WorkbookSheet {
    var name: String
    var relationshipID: String
    var state: String
}

struct SlotOccurrence {
    var start: Date
    var end: Date
    var sheetName: String
    var cellReference: String
    var slotLabel: String
    var isAllDay: Bool
}

struct ReservationEvent: Identifiable {
    var id: String { syncKey }
    var syncKey: String
    var sourceID: String
    var sourceName: String
    var sourceLink: String
    var bookingID: String
    var calendarName: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var sheetNames: [String]
    var cellReferences: [String]
}

struct EventAction {
    var status: String
    var title: String
    var start: Date
    var end: Date
}

struct DeleteCandidate {
    var syncKey: String
    var eventIdentifier: String
    var title: String
    var startISO: String
    var endISO: String
}

struct PendingSyncConfirmation: Identifiable {
    var id = UUID()
    var message: String
}

struct ImageImportUndoRecord {
    var sourceIdentityKey: String
    var calendarName: String
    var beforeSnapshot: [String: StoredEvent]
    var afterSnapshot: [String: StoredEvent]
}

struct ImageImportPlan {
    var source: SourceItem
    var matchedCount: Int
    var createCount: Int
    var updateCount: Int
    var deleteCount: Int
    var reviewRequired: Bool
    var workbookFingerprint: String?
    var previewOutput: String
    var sampleIntervals: [String]
}

struct ImageImportEventEntry: Identifiable {
    let id = UUID()
    var title: String
    let originalTitle: String
    var start: Date
    var end: Date
    let status: String
}

struct ImageImportReview: Identifiable {
    let id = UUID()
    let plan: ImageImportPlan
    var entries: [ImageImportEventEntry]
}

struct SourceSyncReport: Identifiable {
    var id = UUID()
    var sourceItemID: UUID
    var sourceName: String
    var bookingID: String
    var calendarName: String
    var parserLabel: String
    var parserNotes: [String]
    var reviewRequired: Bool
    var workbookFingerprint: String?
    var averageConfidence: Double?
    var minimumConfidence: Double?
    var totalMatchedCount: Int
    var syncedMatchedCount: Int
    var filteredPastCount: Int
    var actions: [EventAction]
    var deleteCandidates: [DeleteCandidate]
    var errorMessage: String?
}

struct SyncRunResult {
    var reports: [SourceSyncReport]
    var outputText: String
}

struct ExtractionResult {
    var allEvents: [ReservationEvent]
    var filteredEvents: [ReservationEvent]
    var filteredPastCount: Int
    var parserLabel: String
    var parserNotes: [String]
    var reviewRequired: Bool
    var workbookFingerprint: String?
    var averageConfidence: Double?
    var minimumConfidence: Double?
}

enum SourceRuntimeStatus: Equatable {
    case idle
    case loading
    case success(matchCount: Int)
    case review(matchCount: Int)
    case failure(String)
}

enum AppFailure: LocalizedError {
    case invalidSource
    case unsupportedSource(String)
    case missingWorkbookData(String)
    case invalidTime(String)
    case invalidAIConfiguration(String)
    case invalidAIResponse(String)
    case calendarAccessDenied
    case calendarNotFound(String)
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "The sheet link or workbook path is invalid."
        case .unsupportedSource(let value):
            return "Unsupported source: \(value)"
        case .missingWorkbookData(let value):
            return "Workbook data is missing: \(value)"
        case .invalidTime(let value):
            return "Invalid time setting: \(value)"
        case .invalidAIConfiguration(let value):
            return "AI parser configuration is incomplete: \(value)"
        case .invalidAIResponse(let value):
            return "AI parser returned invalid data: \(value)"
        case .calendarAccessDenied:
            return "Calendar access was denied."
        case .calendarNotFound(let name):
            return "Calendar not found: \(name)"
        case .syncFailed(let message):
            return message
        }
    }
}

enum CalendarAccessState: Equatable {
    case unknown
    case notDetermined
    case granted
    case denied
    case restricted

    var hasUsableAccess: Bool {
        self == .granted
    }

    var promptButtonTitle: String {
        switch self {
        case .notDetermined:
            return "Grant Calendar Access"
        case .denied, .restricted:
            return "Open Calendar Settings"
        case .granted, .unknown:
            return "Grant Calendar Access"
        }
    }

    var helperText: String? {
        switch self {
        case .unknown:
            return nil
        case .notDetermined:
            return "Calendar access is required before \(appDisplayName) can load or update your calendars. Click Grant Calendar Access to continue."
        case .granted:
            return nil
        case .denied:
            return "Calendar access is off for \(appDisplayName). Open Calendar Settings, then enable access and return to the app."
        case .restricted:
            return "Calendar access is restricted on this Mac. Check Screen Time, MDM, or device privacy restrictions."
        }
    }
}

func currentCalendarAccessState() -> CalendarAccessState {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(macOS 14.0, *) {
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    } else {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }
}
