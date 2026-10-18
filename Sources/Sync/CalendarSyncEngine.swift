import Foundation
import EventKit

actor CalendarSyncEngine {
    let store: CalendarStoreProtocol
    let stateStore: SyncStateStoreProtocol
    let aiNormalizer: AIWorkbookNormalizerProtocol
    let localImageParser: LocalImageParserProtocol
    let workbookDownloader: WorkbookDownloader

    init(
        store: CalendarStoreProtocol = EKEventStore(),
        stateStore: SyncStateStoreProtocol = DefaultSyncStateStore(),
        aiNormalizer: AIWorkbookNormalizerProtocol = DefaultAIWorkbookNormalizer(),
        localImageParser: LocalImageParserProtocol = DefaultLocalImageParser(),
        workbookDownloader: @escaping WorkbookDownloader = { try await downloadWorkbook(from: $0) }
    ) {
        self.store = store
        self.stateStore = stateStore
        self.aiNormalizer = aiNormalizer
        self.localImageParser = localImageParser
        self.workbookDownloader = workbookDownloader
    }

    func calendarAccessState() -> CalendarAccessState {
        currentCalendarAccessState()
    }

    func calendarNamesIfAuthorized() -> [String]? {
        guard currentCalendarAccessState().hasUsableAccess else {
            return nil
        }
        return store.calendars(for: .event)
            .map(\.title)
            .sorted()
    }

    func requestCalendarAccess() async throws {
        try await ensureAccess()
    }

    func calendarNames() async throws -> [String] {
        try await ensureAccess()
        return store.calendars(for: .event)
            .map(\.title)
            .sorted()
    }
}
