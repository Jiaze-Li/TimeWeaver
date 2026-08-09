import Foundation
import EventKit

extension CalendarSyncEngine {
    func findExistingEvent(for event: ReservationEvent, stateRecord: StoredEvent?, calendar: EKCalendar, customURL: URL) -> EKEvent? {
        if let stateRecord,
           let item = store.calendarItem(withIdentifier: stateRecord.eventIdentifier) as? EKEvent {
            return item
        }

        let start = Calendar.current.date(byAdding: .day, value: -2, to: event.start) ?? event.start
        let end = Calendar.current.date(byAdding: .day, value: 2, to: event.end) ?? event.end
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let candidateURLs = Set(eventURLs(for: event.syncKey))
        return store.events(matching: predicate).first(where: { event in
            event.url == customURL || event.url.map { candidateURLs.contains($0) } == true
        })
    }

    func findStaleEvent(candidate: DeleteCandidate, calendar: EKCalendar) -> EKEvent? {
        if let item = store.calendarItem(withIdentifier: candidate.eventIdentifier) as? EKEvent {
            return item
        }

        guard let start = parseFlexibleISO8601(candidate.startISO, timeZone: TimeZone(identifier: defaultSchedulingTimeZoneIdentifier) ?? .current),
              let end = parseFlexibleISO8601(candidate.endISO, timeZone: TimeZone(identifier: defaultSchedulingTimeZoneIdentifier) ?? .current) else {
            return nil
        }
        let predicate = store.predicateForEvents(
            withStart: Calendar.current.date(byAdding: .day, value: -2, to: start) ?? start,
            end: Calendar.current.date(byAdding: .day, value: 2, to: end) ?? end,
            calendars: [calendar]
        )
        let expectedURLs = Set(eventURLs(for: candidate.syncKey))
        return store.events(matching: predicate).first(where: { event in
            event.url.map { expectedURLs.contains($0) } == true
        })
    }

    func findEventForUndo(identifier: String, syncKey: String, start: Date, end: Date, calendar: EKCalendar) -> EKEvent? {
        if let item = store.calendarItem(withIdentifier: identifier) as? EKEvent {
            return item
        }
        let searchStart = Calendar.current.date(byAdding: .day, value: -2, to: start) ?? start
        let searchEnd = Calendar.current.date(byAdding: .day, value: 2, to: end) ?? end
        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: [calendar])
        let expectedURLs = Set(eventURLs(for: syncKey))
        return store.events(matching: predicate).first(where: { event in
            event.url.map { expectedURLs.contains($0) } == true
        })
    }
}
