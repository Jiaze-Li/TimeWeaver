import Foundation
import EventKit

protocol CalendarStoreProtocol {
    func calendars(for entityType: EKEntityType) -> [EKCalendar]
    func calendarItem(withIdentifier identifier: String) -> EKCalendarItem?
    func predicateForEvents(withStart start: Date, end: Date, calendars: [EKCalendar]?) -> NSPredicate
    func events(matching predicate: NSPredicate) -> [EKEvent]
    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws
    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws
    @available(macOS 14.0, *)
    func requestFullAccessToEvents() async throws -> Bool
    func requestAccess(to entityType: EKEntityType, completion: @escaping (Bool, (any Error)?) -> Void)
}

extension EKEventStore: CalendarStoreProtocol {}
