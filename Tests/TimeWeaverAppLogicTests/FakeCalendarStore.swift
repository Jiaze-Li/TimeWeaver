import XCTest
import EventKit
@testable import TimeWeaverCore
@testable import TimeWeaverAppLogic

final class FakeCalendarStore: CalendarStoreProtocol {
    var storedCalendars: [EKCalendar] = []
    var storedEvents: [String: EKEvent] = [:] // id -> EKEvent
    var removedEvents: [String: EKEvent] = [:]
    private let eventStore = EKEventStore()
    private static var isSwizzled = false
    private static var associatedKey: UInt8 = 0

    init() {
        Self.ensureSwizzled()
    }

    private static func ensureSwizzled() {
        guard !isSwizzled else { return }
        isSwizzled = true
        let swizzledBlock: @convention(block) (AnyObject) -> String? = { obj in
            if let custom = objc_getAssociatedObject(obj, &associatedKey) as? String {
                return custom
            }
            return nil
        }
        let newImp = imp_implementationWithBlock(swizzledBlock)
        if let method = class_getInstanceMethod(EKEvent.self, #selector(getter: EKEvent.eventIdentifier)) {
            method_setImplementation(method, newImp)
        }
    }

    func setCustomIdentifier(_ id: String, on event: EKEvent) {
        objc_setAssociatedObject(event, &Self.associatedKey, id, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func addCalendar(title: String) -> EKCalendar {
        let cal = EKCalendar(for: .event, eventStore: eventStore)
        cal.title = title
        storedCalendars.append(cal)
        return cal
    }

    func calendars(for entityType: EKEntityType) -> [EKCalendar] {
        return storedCalendars
    }

    func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? {
        return storedEvents[identifier]
    }

    func predicateForEvents(withStart start: Date, end: Date, calendars: [EKCalendar]?) -> NSPredicate {
        NSPredicate { object, _ in
            guard let event = object as? EKEvent else { return false }
            if let calendars = calendars, !calendars.isEmpty {
                guard let eventCal = event.calendar, calendars.contains(where: { $0.title == eventCal.title }) else {
                    return false
                }
            }
            return event.startDate < end && event.endDate > start
        }
    }

    func events(matching predicate: NSPredicate) -> [EKEvent] {
        return storedEvents.values.filter { predicate.evaluate(with: $0) }
    }

    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        if event.eventIdentifier == nil || event.eventIdentifier.isEmpty {
            let id = UUID().uuidString
            setCustomIdentifier(id, on: event)
        }
        storedEvents[event.eventIdentifier] = event
    }

    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        if let id = event.eventIdentifier {
            storedEvents.removeValue(forKey: id)
            removedEvents[id] = event
        }
    }

    func makeEvent() -> EKEvent {
        return EKEvent(eventStore: eventStore)
    }

    @available(macOS 14.0, *)
    func requestFullAccessToEvents() async throws -> Bool {
        return true
    }

    func requestAccess(to entityType: EKEntityType, completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        completion(true, nil)
    }
}

final class MemorySyncStateStore: SyncStateStoreProtocol {
    var state: SyncState

    init(state: SyncState = SyncState()) {
        self.state = state
    }

    func loadState() -> SyncState {
        return state
    }

    func saveState(_ state: SyncState) {
        self.state = state
    }
}
