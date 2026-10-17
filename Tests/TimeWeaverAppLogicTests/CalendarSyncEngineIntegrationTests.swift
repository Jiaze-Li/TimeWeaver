import XCTest
import EventKit
@testable import TimeWeaverCore
@testable import TimeWeaverAppLogic

final class CalendarSyncEngineIntegrationTests: XCTestCase {

    private func makeDate(day: Int = 20, hour: Int, minute: Int = 0) -> Date {
        var comp = DateComponents()
        comp.year = 2026
        comp.month = 10
        comp.day = day
        comp.hour = hour
        comp.minute = minute
        comp.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return Calendar(identifier: .gregorian).date(from: comp)!
    }

    // 1. Rename Source: does not duplicate events and preserves stability
    func testSourceRenamePreservesEventIdentityWithoutDuplication() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let sourceID = UUID()
        let source1 = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Initial Name",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-100",
            calendar: "Default"
        )

        let start = makeDate(hour: 10)
        let end = makeDate(hour: 11)
        let event1 = ReservationEvent(
            syncKey: "digest-1",
            legacySyncKey: nil,
            sourceID: source1.id.uuidString,
            sourceName: "Team Meeting",
            sourceLink: "",
            bookingID: "BK-100",
            calendarName: "Default",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )

        let extraction1 = ExtractionResult(
            allEvents: [event1],
            filteredEvents: [event1],
            filteredPastCount: 0,
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false
        )

        var state = SyncState()
        let report1 = try await engine.syncSource(
            source: source1,
            extraction: extraction1,
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )

        XCTAssertEqual(report1.actions.count, 1)
        XCTAssertEqual(report1.actions.first?.status, "created")
        XCTAssertEqual(fakeStore.storedEvents.count, 1)

        // Rename the source item
        let source2 = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Renamed Source",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-100",
            calendar: "Default"
        )

        // Event now has source2's name, but identical stable ID and same syncKey
        let event2 = ReservationEvent(
            syncKey: "digest-1",
            legacySyncKey: nil,
            sourceID: source2.id.uuidString,
            sourceName: "Team Meeting",
            sourceLink: "",
            bookingID: "BK-100",
            calendarName: "Default",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )
        let extraction2 = ExtractionResult(
            allEvents: [event2],
            filteredEvents: [event2],
            filteredPastCount: 0,
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false
        )

        let report2 = try await engine.syncSource(
            source: source2,
            extraction: extraction2,
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )

        XCTAssertEqual(report2.actions.count, 1)
        XCTAssertEqual(report2.actions.first?.status, "unchanged")
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Renaming source must not create duplicate events")
    }

    // 2. Change Booking ID: matches existing events via time/source, does not duplicate or delete
    func testBookingIDChangeMigratesWithoutDuplication() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let sourceID = UUID()
        let source1 = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Lab",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-OLD",
            calendar: "Default"
        )

        let start = makeDate(hour: 14)
        let end = makeDate(hour: 16)
        let oldSyncKey = "old-key-with-booking-id"
        let event1 = ReservationEvent(
            syncKey: oldSyncKey,
            legacySyncKey: nil,
            sourceID: source1.id.uuidString,
            sourceName: "Lab Booking",
            sourceLink: "",
            bookingID: "BK-OLD",
            calendarName: "Default",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["B5"]
        )

        var state = SyncState()
        _ = try await engine.syncSource(
            source: source1,
            extraction: ExtractionResult(allEvents: [event1], filteredEvents: [event1], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        XCTAssertEqual(fakeStore.storedEvents.count, 1)
        let initialEventID = fakeStore.storedEvents.keys.first

        // Now user updates bookingID to BK-NEW
        let source2 = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Lab",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-NEW",
            calendar: "Default"
        )
        // With stable syncKey (independent of bookingID), let's say the new syncKey is stable-key
        let newSyncKey = "stable-key-without-booking-id"
        let event2 = ReservationEvent(
            syncKey: newSyncKey,
            legacySyncKey: nil,
            sourceID: source2.id.uuidString,
            sourceName: "Lab Booking",
            sourceLink: "",
            bookingID: "BK-NEW",
            calendarName: "Default",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["B5"]
        )

        let report2 = try await engine.syncSource(
            source: source2,
            extraction: ExtractionResult(allEvents: [event2], filteredEvents: [event2], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )

        // The syncKey changed so the URL changed, meaning the event is updated in-place without duplication
        XCTAssertEqual(report2.actions.first?.status, "updated")
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Should not duplicate event when bookingID changes")
        XCTAssertEqual(report2.deleteCandidates.count, 0, "Should not trigger stale deletion of the old event")
        XCTAssertEqual(state.events[newSyncKey]?.eventIdentifier, initialEventID)
        XCTAssertNil(state.events[oldSyncKey], "Old key should be cleaned up from state")
    }

    // 3. Change Target Calendar: event migrated to new calendar, old calendar event cleaned up
    func testTargetCalendarChangeMigratesToNewCalendar() async throws {
        let fakeStore = FakeCalendarStore()
        let calOld = fakeStore.addCalendar(title: "OldCalendar")
        let calNew = fakeStore.addCalendar(title: "NewCalendar")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let sourceID = UUID()
        let source1 = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Lab",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-1",
            calendar: "OldCalendar"
        )

        let start = makeDate(hour: 9)
        let end = makeDate(hour: 10)
        let event1 = ReservationEvent(
            syncKey: "key-cal-test",
            legacySyncKey: nil,
            sourceID: source1.id.uuidString,
            sourceName: "Meeting",
            sourceLink: "",
            bookingID: "BK-1",
            calendarName: "OldCalendar",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["C1"]
        )

        var state = SyncState()
        _ = try await engine.syncSource(
            source: source1,
            extraction: ExtractionResult(allEvents: [event1], filteredEvents: [event1], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )

        XCTAssertEqual(fakeStore.storedEvents.count, 1)
        let initialEvent = fakeStore.storedEvents.values.first
        XCTAssertEqual(initialEvent?.calendar?.title, calOld.title)

        // Now change calendar to NewCalendar
        let source2 = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Lab",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-1",
            calendar: "NewCalendar"
        )
        let event2 = ReservationEvent(
            syncKey: "key-cal-test",
            legacySyncKey: nil,
            sourceID: source2.id.uuidString,
            sourceName: "Meeting",
            sourceLink: "",
            bookingID: "BK-1",
            calendarName: "NewCalendar",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["C1"]
        )

        let report2 = try await engine.syncSource(
            source: source2,
            extraction: ExtractionResult(allEvents: [event2], filteredEvents: [event2], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )

        XCTAssertEqual(report2.actions.first?.status, "created")
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Old event deleted and new one created in new calendar")
        let migratedEvent = fakeStore.storedEvents.values.first
        XCTAssertEqual(migratedEvent?.calendar?.title, calNew.title)
        XCTAssertEqual(fakeStore.removedEvents.count, 1, "Old event should have been removed from old calendar")
    }

    // 4. Image Import Overrides: edited title and start/end are applied and validated
    func testImageImportOverridesAppliedCorrectly() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Image Schedule",
            source: "/path/to/photo.png",
            bookingID: "",
            calendar: "Default"
        )

        let originalStart = makeDate(hour: 8)
        let originalEnd = makeDate(hour: 9)
        let syncKey = "image-slot-1"
        let event = ReservationEvent(
            syncKey: syncKey,
            legacySyncKey: nil,
            sourceID: source.id.uuidString,
            sourceName: "Original Title",
            sourceLink: "",
            bookingID: "",
            calendarName: "Default",
            start: originalStart,
            end: originalEnd,
            isAllDay: false,
            sheetNames: [],
            cellReferences: []
        )

        let modifiedStart = makeDate(hour: 10, minute: 30)
        let modifiedEnd = makeDate(hour: 12, minute: 0)
        let overrides: [String: EventOverride] = [
            syncKey: EventOverride(title: "User Modified Title", start: modifiedStart, end: modifiedEnd)
        ]

        var state = SyncState()
        let report = try await engine.syncSource(
            source: source,
            extraction: ExtractionResult(allEvents: [event], filteredEvents: [event], filteredPastCount: 0, parserLabel: "Vision", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: [],
            eventOverrides: overrides
        )

        XCTAssertEqual(report.actions.first?.title, "User Modified Title")
        XCTAssertEqual(report.actions.first?.start, modifiedStart)
        XCTAssertEqual(report.actions.first?.end, modifiedEnd)

        let savedEvent = fakeStore.storedEvents.values.first
        XCTAssertEqual(savedEvent?.title, "User Modified Title")
        XCTAssertEqual(savedEvent?.startDate, modifiedStart)
        XCTAssertEqual(savedEvent?.endDate, modifiedEnd)

        // Invalid override start >= end must throw AppFailure.invalidTime
        let invalidOverrides: [String: EventOverride] = [
            syncKey: EventOverride(title: "Bad", start: modifiedEnd, end: modifiedStart)
        ]
        do {
            _ = try await engine.syncSource(
                source: source,
                extraction: ExtractionResult(allEvents: [event], filteredEvents: [event], filteredPastCount: 0, parserLabel: "Vision", parserNotes: [], reviewRequired: false),
                state: &state,
                upcomingOnly: false,
                previewOnly: false,
                aiApprovals: [],
                eventOverrides: invalidOverrides
            )
            XCTFail("Should fail with invalid time interval")
        } catch AppFailure.invalidTime {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // 5. Repeat Sync Idempotency
    func testRepeatSyncIsIdempotent() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Weekly Schedule",
            source: "/path/to/sheet.xlsx",
            bookingID: "TEAM",
            calendar: "Default"
        )

        let start = makeDate(hour: 15)
        let end = makeDate(hour: 16)
        let event = ReservationEvent(
            syncKey: "idempotent-key",
            legacySyncKey: nil,
            sourceID: source.id.uuidString,
            sourceName: "Weekly Sync",
            sourceLink: "",
            bookingID: "TEAM",
            calendarName: "Default",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["D4"]
        )
        let extraction = ExtractionResult(allEvents: [event], filteredEvents: [event], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false)

        var state = SyncState()
        let report1 = try await engine.syncSource(
            source: source,
            extraction: extraction,
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        XCTAssertEqual(report1.actions.first?.status, "created")
        XCTAssertEqual(fakeStore.storedEvents.count, 1)

        // Second sync with identical data
        let report2 = try await engine.syncSource(
            source: source,
            extraction: extraction,
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        XCTAssertEqual(report2.actions.first?.status, "unchanged")
        XCTAssertEqual(report2.deleteCandidates.count, 0)
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Event count must remain 1 after repeated sync")
    }

    // 6. Undo Revert Image Import
    func testRevertImageImportRestoresStateAndEvents() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Photo",
            source: "/path/to/photo.png",
            bookingID: "",
            calendar: "Default"
        )

        let start = makeDate(hour: 11)
        let end = makeDate(hour: 12)
        let syncKey = "undo-slot-1"
        let event = ReservationEvent(
            syncKey: syncKey,
            legacySyncKey: nil,
            sourceID: source.id.uuidString,
            sourceName: "Undo Test",
            sourceLink: "",
            bookingID: "",
            calendarName: "Default",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: [],
            cellReferences: []
        )

        var state = SyncState()
        let beforeSnapshot = state.events

        _ = try await engine.syncSource(
            source: source,
            extraction: ExtractionResult(allEvents: [event], filteredEvents: [event], filteredPastCount: 0, parserLabel: "Vision", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        stateStore.saveState(state)

        let afterSnapshot = state.events
        XCTAssertEqual(fakeStore.storedEvents.count, 1)
        XCTAssertEqual(afterSnapshot.count, 1)

        let undoRecord = ImageImportUndoRecord(
            sourceIdentityKey: source.id.uuidString,
            calendarName: "Default",
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot
        )

        let undoSummary = try await engine.revertImageImport(
            record: undoRecord,
            schedulingTimeZoneIdentifier: "Asia/Shanghai"
        )

        XCTAssertTrue(undoSummary.contains("Removed 1"), "Summary should state 1 event was removed")
        XCTAssertEqual(fakeStore.storedEvents.count, 0, "FakeStore events should be empty after undo")
        let finalState = stateStore.loadState()
        XCTAssertEqual(finalState.events.count, 0, "SyncState should be back to empty")
    }
}
