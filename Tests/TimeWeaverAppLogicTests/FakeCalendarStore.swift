import XCTest
import EventKit
@testable import TimeWeaverCore
@testable import TimeWeaverAppLogic

final class FakeCalendarStore: CalendarStoreProtocol {
    var storedCalendars: [EKCalendar] = []
    var storedEvents: [String: EKEvent] = [:] // id -> EKEvent
    var removedEvents: [String: EKEvent] = [:]
    var shouldFailSave: Bool = false
    var shouldFailRemove: Bool = false
    var removeFailureIdentifier: String? = nil
    private let eventStore = EKEventStore()
    private static var associatedKey: UInt8 = 0
    private static let fakeSubclass: AnyClass? = {
        guard let originalClass = objc_getClass("EKEvent") as? AnyClass else { return nil }
        let subclassName = "FakeEKEventSubclass_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        guard let subcls = objc_allocateClassPair(originalClass, subclassName, 0) else { return nil }
        
        let idGetterBlock: @convention(block) (AnyObject) -> String? = { obj in
            if let custom = objc_getAssociatedObject(obj, &FakeCalendarStore.associatedKey) as? String {
                return custom
            }
            return nil
        }
        let imp = imp_implementationWithBlock(idGetterBlock)
        let selector = #selector(getter: EKEvent.eventIdentifier)
        if let originalMethod = class_getInstanceMethod(originalClass, selector) {
            let types = method_getTypeEncoding(originalMethod)
            class_addMethod(subcls, selector, imp, types)
        }
        objc_registerClassPair(subcls)
        return subcls
    }()

    init() {}

    func setCustomIdentifier(_ id: String, on event: EKEvent) {
        if let subcls = Self.fakeSubclass {
            object_setClass(event, subcls)
        }
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
        if shouldFailSave {
            throw AppFailure.syncFailed("Injected save failure")
        }
        if event.eventIdentifier == nil || event.eventIdentifier.isEmpty {
            let id = UUID().uuidString
            setCustomIdentifier(id, on: event)
        }
        storedEvents[event.eventIdentifier] = event
    }

    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        if shouldFailRemove || (removeFailureIdentifier != nil && event.eventIdentifier == removeFailureIdentifier) {
            throw AppFailure.syncFailed("Injected remove failure")
        }
        if let id = event.eventIdentifier {
            storedEvents.removeValue(forKey: id)
            removedEvents[id] = event
        }
    }

    func makeEvent() -> EKEvent {
        let event = EKEvent(eventStore: eventStore)
        if let subcls = Self.fakeSubclass {
            object_setClass(event, subcls)
        }
        return event
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
