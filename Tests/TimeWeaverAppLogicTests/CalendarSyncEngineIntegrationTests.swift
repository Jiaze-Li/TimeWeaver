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

    // 7. P1-1: Deletion protection actively prevents deletion when unauthorized, and permits deletion when authorized
    func testUnauthorizedSuspiciousDeletionDoesNotDeleteEvents() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Suspicious Test",
            source: "/path/to/sheet.xlsx",
            bookingID: "TEAM",
            calendar: "Default"
        )

        let start = makeDate(hour: 14)
        let end = makeDate(hour: 15)
        let event = ReservationEvent(
            syncKey: "suspicious-key-1",
            legacySyncKey: nil,
            sourceID: source.id.uuidString,
            sourceName: "Existing Event",
            sourceLink: "",
            bookingID: "TEAM",
            calendarName: "Default",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )

        // Seed 1 event
        var state = SyncState()
        _ = try await engine.syncSource(
            source: source,
            extraction: ExtractionResult(allEvents: [event], filteredEvents: [event], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        XCTAssertEqual(fakeStore.storedEvents.count, 1)

        // Now parser returns 0 events (suspicious deletion)
        let emptyExtraction = ExtractionResult(allEvents: [], filteredEvents: [], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false)

        // Run sync WITHOUT authorization
        let unauthReport = try await engine.syncSource(
            source: source,
            extraction: emptyExtraction,
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: [],
            authorizedDeletionSourceIDs: []
        )

        XCTAssertTrue(unauthReport.isSuspiciousDeletion)
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Calendar event must NOT be deleted without authorization")
        XCTAssertEqual(state.events.count, 1, "SyncState must preserve tracked events when deletion is suspicious and unauthorized")
        XCTAssertEqual(unauthReport.actions.first?.status, "deletion rejected: suspicious")

        // Now run sync WITH explicit authorization
        let authReport = try await engine.syncSource(
            source: source,
            extraction: emptyExtraction,
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: [],
            authorizedDeletionSourceIDs: [source.id]
        )

        XCTAssertTrue(authReport.isSuspiciousDeletion)
        XCTAssertEqual(fakeStore.storedEvents.count, 0, "Calendar event should be deleted when explicitly authorized")
        XCTAssertEqual(state.events.count, 0, "SyncState should remove deleted key")
        XCTAssertEqual(authReport.actions.first?.status, "deleted")
    }

    // 8. P1-2: Cross-calendar migration failure and rollback
    func testCrossCalendarMigrationFailureAndRollback() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "OldCal")
        _ = fakeStore.addCalendar(title: "NewCal")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let sourceID = UUID()
        let sourceOld = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Rollback Test",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-1",
            calendar: "OldCal"
        )

        let start = makeDate(hour: 10)
        let end = makeDate(hour: 11)
        let eventOld = ReservationEvent(
            syncKey: "migration-key-1",
            legacySyncKey: nil,
            sourceID: sourceOld.id.uuidString,
            sourceName: "Meeting",
            sourceLink: "",
            bookingID: "BK-1",
            calendarName: "OldCal",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )

        var state = SyncState()
        _ = try await engine.syncSource(
            source: sourceOld,
            extraction: ExtractionResult(allEvents: [eventOld], filteredEvents: [eventOld], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        XCTAssertEqual(fakeStore.storedEvents.count, 1)

        let sourceNew = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Rollback Test",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-1",
            calendar: "NewCal"
        )
        let eventNew = ReservationEvent(
            syncKey: "migration-key-1",
            legacySyncKey: nil,
            sourceID: sourceNew.id.uuidString,
            sourceName: "Meeting",
            sourceLink: "",
            bookingID: "BK-1",
            calendarName: "NewCal",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )

        let oldEventID = fakeStore.storedEvents.keys.first!
        // Inject remove failure when deleting old event during cross-calendar move
        fakeStore.removeFailureIdentifier = oldEventID

        do {
            _ = try await engine.syncSource(
                source: sourceNew,
                extraction: ExtractionResult(allEvents: [eventNew], filteredEvents: [eventNew], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
                state: &state,
                upcomingOnly: false,
                previewOnly: false,
                aiApprovals: []
            )
            XCTFail("Should have thrown remove failure")
        } catch {
            // Error caught; verify rollback occurred: new event removed, old event kept, no duplicate
            XCTAssertEqual(fakeStore.storedEvents.count, 1, "Should rollback newly created event so only 1 event remains")
            let remaining = fakeStore.storedEvents.values.first
            XCTAssertEqual(remaining?.calendar?.title, "OldCal", "Old event must be preserved in OldCal")
        }
    }

    // 9. P1-3: Historical FNV-1a Hash Source Identity Migration with Real Data
    func testHistoricalLegacyHashMigrationRealData() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        // User had an old source before the stable UUID model
        let oldName = "Historic Room"
        let oldSource = "/path/to/historic.xlsx"
        let oldBookingID = "OLD-999"
        let oldCalendar = "Default"
        let legacySourceID = TimeWeaverCore.fnv1a64Hex("\(oldName)|\(oldSource)|\(oldBookingID)|\(oldCalendar)")
        let legacySyncKey = TimeWeaverCore.fnv1a64Hex("\(legacySourceID)|Sheet1|B2|\(oldBookingID)")

        let start = makeDate(hour: 9)
        let end = makeDate(hour: 10)
        // Authentic legacy URL format used by PPMSCalendarSync
        let legacyURL = URL(string: "ppms-sync://event/\(legacySyncKey)")!

        // Seed old event in FakeCalendarStore with the legacy URL
        let existingEvent = fakeStore.makeEvent()
        existingEvent.calendar = fakeStore.calendars(for: .event).first
        existingEvent.title = "Historic Meeting"
        existingEvent.startDate = start
        existingEvent.endDate = end
        existingEvent.url = legacyURL
        try fakeStore.save(existingEvent, span: .thisEvent, commit: true)
        let realEKID = existingEvent.eventIdentifier!

        // Seed an unrelated event with a different URL at the exact same time
        let otherSyncKey = "other-unrelated-sync-key"
        let otherEvent = fakeStore.makeEvent()
        otherEvent.calendar = fakeStore.calendars(for: .event).first
        otherEvent.title = "Unrelated Meeting"
        otherEvent.startDate = start
        otherEvent.endDate = end
        otherEvent.url = URL(string: "ppms-sync://event/\(otherSyncKey)")!
        try fakeStore.save(otherEvent, span: .thisEvent, commit: true)

        // Seed state with an expired/stale eventIdentifier to force fallback to predicate + legacy URL matching
        var state = SyncState()
        state.events[legacySyncKey] = StoredEvent(
            eventIdentifier: "STALE-EXPIRED-IDENTIFIER-NOT-IN-STORE",
            sourceID: legacySourceID,
            calendar: oldCalendar,
            title: "Historic Meeting",
            startISO: iso8601(start),
            endISO: iso8601(end)
        )

        // User now runs TimeWeaver with new stable UUID SourceItem, but Source attributes are identical
        let sourceItem = SourceItem(
            id: UUID(),
            enabled: true,
            name: oldName,
            source: oldSource,
            bookingID: oldBookingID,
            calendar: oldCalendar
        )

        let newSyncKey = TimeWeaverCore.fnv1a64Hex("\(sourceItem.stableIdentity)|Sheet1|B2")
        let newEvent = ReservationEvent(
            syncKey: newSyncKey,
            legacySyncKey: legacySyncKey,
            sourceID: sourceItem.stableIdentity,
            sourceName: "Historic Meeting",
            sourceLink: "",
            bookingID: oldBookingID,
            calendarName: oldCalendar,
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["B2"]
        )

        let report = try await engine.syncSource(
            source: sourceItem,
            extraction: ExtractionResult(allEvents: [newEvent], filteredEvents: [newEvent], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )

        // Verify: The event was matched via legacy ppms-sync URL fallback despite stale identifier
        // Unrelated event must NOT be erroneously claimed
        XCTAssertEqual(fakeStore.storedEvents.count, 2, "Must not duplicate historical event, and other event must remain")
        XCTAssertEqual(state.events.count, 1, "Must have exactly 1 event in state for this source")
        XCTAssertNil(state.events[legacySyncKey], "Legacy sync key must be migrated away")
        XCTAssertNotNil(state.events[newSyncKey], "New stable sync key must be stored")
        XCTAssertEqual(state.events[newSyncKey]?.eventIdentifier, realEKID, "Matched event should be the historic event via URL, not the unrelated event")
        XCTAssertEqual(state.events[newSyncKey]?.sourceID, sourceItem.stableIdentity)
    }

    // 10. P1-4: Undo Updates Same Event In-Place Without Recreation
    func testUndoUpdatesSameEventInPlaceWithoutRecreation() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Undo In Place",
            source: "/path/to/img.png",
            bookingID: "TEST",
            calendar: "Default"
        )

        let start = makeDate(hour: 10)
        let end = makeDate(hour: 11)
        let syncKey = "inplace-undo-key"

        // Create initial event
        let event = fakeStore.makeEvent()
        event.calendar = fakeStore.calendars(for: .event).first
        event.title = "Original Title"
        event.startDate = start
        event.endDate = end
        event.url = URL(string: "timeweaver://event?key=\(syncKey)")
        try fakeStore.save(event, span: .thisEvent, commit: true)
        let eventID = event.eventIdentifier!

        let beforeSnapshot: [String: StoredEvent] = [
            syncKey: StoredEvent(
                eventIdentifier: eventID,
                sourceID: source.stableIdentity,
                calendar: "Default",
                title: "Original Title",
                startISO: iso8601(start),
                endISO: iso8601(end)
            )
        ]

        // User imported an update (title and time modified)
        let newStart = makeDate(hour: 11)
        let newEnd = makeDate(hour: 12)
        event.title = "Updated Title"
        event.startDate = newStart
        event.endDate = newEnd
        try fakeStore.save(event, span: .thisEvent, commit: true)

        let afterSnapshot: [String: StoredEvent] = [
            syncKey: StoredEvent(
                eventIdentifier: eventID, // same EKEvent identifier
                sourceID: source.stableIdentity,
                calendar: "Default",
                title: "Updated Title",
                startISO: iso8601(newStart),
                endISO: iso8601(newEnd)
            )
        ]

        let undoRecord = ImageImportUndoRecord(
            sourceIdentityKey: source.stableIdentity,
            calendarName: "Default",
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot
        )

        let undoResult = try await engine.revertImageImport(
            record: undoRecord,
            schedulingTimeZoneIdentifier: "Asia/Shanghai"
        )

        XCTAssertTrue(undoResult.contains("Restored 1"))
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Must not create duplicate events")
        let restored = fakeStore.storedEvents[eventID]
        XCTAssertNotNil(restored, "Original event ID must be preserved")
        XCTAssertEqual(restored?.title, "Original Title")
        XCTAssertEqual(restored?.startDate, start)
        XCTAssertEqual(restored?.endDate, end)
    }

    // 11. P2-1: Preview does not mutate existing EKEvent objects in memory
    func testPreviewDoesNotMutateExistingEKEventInMemory() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Preview Imm Name",
            source: "/path/to/sheet.xlsx",
            bookingID: "TEAM",
            calendar: "Default"
        )

        let originalStart = makeDate(hour: 10)
        let originalEnd = makeDate(hour: 11)
        let syncKey = "preview-imm-key"

        let existingEvent = fakeStore.makeEvent()
        existingEvent.calendar = fakeStore.calendars(for: .event).first
        existingEvent.title = "Original EK Title"
        existingEvent.startDate = originalStart
        existingEvent.endDate = originalEnd
        existingEvent.notes = "Original Notes"
        existingEvent.url = URL(string: "timeweaver://event?key=\(syncKey)")
        try fakeStore.save(existingEvent, span: .thisEvent, commit: true)
        let originalID = existingEvent.eventIdentifier!

        var state = SyncState()
        state.events[syncKey] = StoredEvent(
            eventIdentifier: originalID,
            sourceID: source.stableIdentity,
            calendar: "Default",
            title: "Original EK Title",
            startISO: iso8601(originalStart),
            endISO: iso8601(originalEnd)
        )

        // Incoming extraction proposes different title and times
        let proposedStart = makeDate(hour: 14)
        let proposedEnd = makeDate(hour: 16)
        let incomingEvent = ReservationEvent(
            syncKey: syncKey,
            legacySyncKey: nil,
            sourceID: source.stableIdentity,
            sourceName: "New Proposed Title",
            sourceLink: "New Notes",
            bookingID: "TEAM",
            calendarName: "Default",
            start: proposedStart,
            end: proposedEnd,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["Z9"]
        )

        let previewReport = try await engine.syncSource(
            source: source,
            extraction: ExtractionResult(allEvents: [incomingEvent], filteredEvents: [incomingEvent], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: true, // Preview mode!
            aiApprovals: []
        )

        XCTAssertEqual(previewReport.actions.first?.status, "would update")

        // Critical verification: The EKEvent object in memory must NOT have been mutated!
        let storedInFake = fakeStore.storedEvents[originalID]
        XCTAssertEqual(storedInFake?.title, "Original EK Title", "Preview must not mutate existing EKEvent title")
        XCTAssertEqual(storedInFake?.startDate, originalStart, "Preview must not mutate existing EKEvent start date")
        XCTAssertEqual(storedInFake?.endDate, originalEnd, "Preview must not mutate existing EKEvent end date")
        XCTAssertEqual(storedInFake?.notes, "Original Notes", "Preview must not mutate existing EKEvent notes")
    }

    // 12. P2-3: Cross-calendar migration double failure (remove old fails AND rollback fails) throws explicit error
    func testCrossCalendarMigrationDoubleFailureThrowsExplicitError() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "OldCal")
        _ = fakeStore.addCalendar(title: "NewCal")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let sourceID = UUID()
        let sourceOld = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Double Failure Test",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-1",
            calendar: "OldCal"
        )

        let start = makeDate(hour: 10)
        let end = makeDate(hour: 11)
        let eventOld = ReservationEvent(
            syncKey: "double-fail-key",
            legacySyncKey: nil,
            sourceID: sourceOld.id.uuidString,
            sourceName: "Meeting",
            sourceLink: "",
            bookingID: "BK-1",
            calendarName: "OldCal",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )

        var state = SyncState()
        _ = try await engine.syncSource(
            source: sourceOld,
            extraction: ExtractionResult(allEvents: [eventOld], filteredEvents: [eventOld], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        XCTAssertEqual(fakeStore.storedEvents.count, 1)

        let sourceNew = SourceItem(
            id: sourceID,
            enabled: true,
            name: "Double Failure Test",
            source: "/path/to/sheet.xlsx",
            bookingID: "BK-1",
            calendar: "NewCal"
        )
        let eventNew = ReservationEvent(
            syncKey: "double-fail-key",
            legacySyncKey: nil,
            sourceID: sourceNew.id.uuidString,
            sourceName: "Meeting",
            sourceLink: "",
            bookingID: "BK-1",
            calendarName: "NewCal",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )

        // Inject global remove failure: removing old event fails AND rollback removing new event also fails
        fakeStore.shouldFailRemove = true

        do {
            _ = try await engine.syncSource(
                source: sourceNew,
                extraction: ExtractionResult(allEvents: [eventNew], filteredEvents: [eventNew], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
                state: &state,
                upcomingOnly: false,
                previewOnly: false,
                aiApprovals: []
            )
            XCTFail("Should have thrown explicit double failure")
        } catch let error as AppFailure {
            switch error {
            case .syncFailed(let msg):
                XCTAssertTrue(msg.contains("Cross-calendar migration failed: could not remove old event"), "Error message must report migration failure: \(msg)")
                XCTAssertTrue(msg.contains("rollback removal of new event"), "Error message must report rollback failure: \(msg)")
            default:
                XCTFail("Unexpected error type: \(error)")
            }
        } catch {
            XCTFail("Expected AppFailure.syncFailed but got \(error)")
        }
    }

    // 13. P2-2: Undo failure retains undo record for retry without duplicating events
    func testUndoFailureRetainsUndoRecordForRetry() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Undo Fail Test",
            source: "/path/to/img.png",
            bookingID: "TEST",
            calendar: "Default"
        )

        let start = makeDate(hour: 10)
        let end = makeDate(hour: 11)
        let syncKey = "undo-fail-key"

        let event = fakeStore.makeEvent()
        event.calendar = fakeStore.calendars(for: .event).first
        event.title = "Original Title"
        event.startDate = start
        event.endDate = end
        event.url = URL(string: "timeweaver://event?key=\(syncKey)")
        try fakeStore.save(event, span: .thisEvent, commit: true)
        let eventID = event.eventIdentifier!

        let beforeSnapshot: [String: StoredEvent] = [:]
        let afterSnapshot: [String: StoredEvent] = [
            syncKey: StoredEvent(
                eventIdentifier: eventID,
                sourceID: source.stableIdentity,
                calendar: "Default",
                title: "Created Title",
                startISO: iso8601(start),
                endISO: iso8601(end)
            )
        ]

        let undoRecord = ImageImportUndoRecord(
            sourceIdentityKey: source.stableIdentity,
            calendarName: "Default",
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot
        )

        // Inject remove failure during revert
        fakeStore.shouldFailRemove = true

        do {
            _ = try await engine.revertImageImport(
                record: undoRecord,
                schedulingTimeZoneIdentifier: "Asia/Shanghai"
            )
            XCTFail("Should fail remove during undo")
        } catch {
            // Revert failed; event remains in store
            XCTAssertEqual(fakeStore.storedEvents.count, 1)
        }

        // Now fix the failure condition and retry
        fakeStore.shouldFailRemove = false
        let undoSummary = try await engine.revertImageImport(
            record: undoRecord,
            schedulingTimeZoneIdentifier: "Asia/Shanghai"
        )
        XCTAssertTrue(undoSummary.contains("Removed 1"))
        XCTAssertEqual(fakeStore.storedEvents.count, 0, "Event removed successfully upon retry")
    }

    // 14. P2-1: Auto-sync settings regression tests
    func testAutoSyncSettingsCombinations() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Auto Sync Test",
            source: "/path/to/sheet.xlsx",
            bookingID: "TEAM",
            calendar: "Default"
        )

        let start1 = makeDate(hour: 9)
        let end1 = makeDate(hour: 10)
        let event1 = ReservationEvent(
            syncKey: "auto-sync-key-1",
            legacySyncKey: nil,
            sourceID: source.stableIdentity,
            sourceName: "Event 1",
            sourceLink: "",
            bookingID: "TEAM",
            calendarName: "Default",
            start: start1,
            end: end1,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )

        let start2 = makeDate(hour: 11)
        let end2 = makeDate(hour: 12)
        let event2 = ReservationEvent(
            syncKey: "auto-sync-key-2",
            legacySyncKey: nil,
            sourceID: source.stableIdentity,
            sourceName: "Event 2",
            sourceLink: "",
            bookingID: "TEAM",
            calendarName: "Default",
            start: start2,
            end: end2,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A2"]
        )

        // Seed 2 events
        var state = SyncState()
        _ = try await engine.syncSource(
            source: source,
            extraction: ExtractionResult(allEvents: [event1, event2], filteredEvents: [event1, event2], filteredPastCount: 0, parserLabel: "Rule", parserNotes: [], reviewRequired: false),
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        XCTAssertEqual(fakeStore.storedEvents.count, 2)

        // Case A: Extractor now returns only event1 (event2 is an ordinary removal, not suspicious because extractedCount = 1 > 0)
        let ordinaryRemovalExtraction = ExtractionResult(
            allEvents: [event1],
            filteredEvents: [event1],
            filteredPastCount: 0,
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false
        )

        // Preview ordinary removal:
        let previewReport = try await engine.syncSource(
            source: source,
            extraction: ordinaryRemovalExtraction,
            state: &state,
            upcomingOnly: false,
            previewOnly: true,
            aiApprovals: []
        )
        XCTAssertFalse(previewReport.isSuspiciousDeletion, "Ordinary deletion is not suspicious")
        XCTAssertEqual(previewReport.actions.filter { $0.status == "would delete" }.count, 1)

        // Case B: Ordinary deletion with confirmBeforeDeletion = false allows sync execution to proceed
        // (In execution, syncSource with isDeletionAuthorized removes the stale event)
        let executeReport = try await engine.syncSource(
            source: source,
            extraction: ordinaryRemovalExtraction,
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: []
        )
        XCTAssertEqual(executeReport.actions.filter { $0.status == "deleted" }.count, 1)
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Ordinary deletion executed when authorized")

        // Case C: Suspicious deletion (extractedCount = 0 with tracked events present)
        let suspiciousExtraction = ExtractionResult(
            allEvents: [],
            filteredEvents: [],
            filteredPastCount: 0,
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false
        )
        let suspReport = try await engine.syncSource(
            source: source,
            extraction: suspiciousExtraction,
            state: &state,
            upcomingOnly: false,
            previewOnly: false,
            aiApprovals: [],
            authorizedDeletionSourceIDs: []
        )
        XCTAssertTrue(suspReport.isSuspiciousDeletion)
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Suspicious deletion blocked from removing remaining event")
        XCTAssertEqual(suspReport.actions.first?.status, "deletion rejected: suspicious")
    }

    // 15. Undo Partial Restore Failure Then Retry Is Idempotent
    func testUndoPartialRestoreFailureThenRetryIsIdempotent() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Default")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "Partial Undo Test",
            source: "/path/to/img.png",
            bookingID: "TEST",
            calendar: "Default"
        )

        let startA = makeDate(hour: 9)
        let endA = makeDate(hour: 10)
        let startB = makeDate(hour: 11)
        let endB = makeDate(hour: 12)
        let syncKeyA = "undo-partial-A"
        let syncKeyB = "undo-partial-B"

        let storedA = StoredEvent(
            eventIdentifier: "HISTORIC-A",
            sourceID: source.stableIdentity,
            calendar: "Default",
            title: "Historic Event A",
            startISO: iso8601(startA),
            endISO: iso8601(endA)
        )
        let storedB = StoredEvent(
            eventIdentifier: "HISTORIC-B",
            sourceID: source.stableIdentity,
            calendar: "Default",
            title: "Historic Event B",
            startISO: iso8601(startB),
            endISO: iso8601(endB)
        )

        // Snapshot before import had A and B; snapshot after import had neither (simulating both deleted)
        let beforeSnapshot: [String: StoredEvent] = [
            syncKeyA: storedA,
            syncKeyB: storedB
        ]
        let afterSnapshot: [String: StoredEvent] = [:]

        let undoRecord = ImageImportUndoRecord(
            sourceIdentityKey: source.stableIdentity,
            calendarName: "Default",
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot
        )

        // Inject save failure specifically for Event B
        fakeStore.saveFailureTitle = "Historic Event B"

        // Step 1: Run Undo. A should restore, B should fail
        do {
            _ = try await engine.revertImageImport(
                record: undoRecord,
                schedulingTimeZoneIdentifier: "Asia/Shanghai"
            )
            XCTFail("Should fail because Event B save fails")
        } catch {
            // Expected failure on Event B
        }

        // Verify partial state: Event A is created in calendar and in SyncState, Event B is not yet created
        XCTAssertEqual(fakeStore.storedEvents.count, 1, "Calendar should have Event A restored")
        let eventA = fakeStore.storedEvents.values.first
        XCTAssertEqual(eventA?.title, "Historic Event A")
        let intermediateState = stateStore.loadState()
        XCTAssertEqual(intermediateState.events.count, 1, "SyncState should record Event A")
        XCTAssertEqual(intermediateState.events[syncKeyA]?.eventIdentifier, eventA?.eventIdentifier)

        // Step 2: Remove the failure condition and retry the EXACT SAME undo operation
        fakeStore.saveFailureTitle = nil

        let summary = try await engine.revertImageImport(
            record: undoRecord,
            schedulingTimeZoneIdentifier: "Asia/Shanghai"
        )
        XCTAssertTrue(summary.contains("Restored"))

        // Step 3: Verify idempotency: Exactly 2 events in calendar (A and B), no duplicates
        XCTAssertEqual(fakeStore.storedEvents.count, 2, "Calendar should contain exactly 2 events without duplicates")
        let titles = Set(fakeStore.storedEvents.values.map(\.title))
        XCTAssertTrue(titles.contains("Historic Event A"), "Should contain Historic Event A")
        XCTAssertTrue(titles.contains("Historic Event B"), "Should contain Historic Event B")

        // Step 4: Verify final SyncState matches actual calendar events
        let finalState = stateStore.loadState()
        XCTAssertEqual(finalState.events.count, 2, "SyncState should contain both events")
        for (key, stored) in finalState.events {
            let actualEvent = fakeStore.storedEvents[stored.eventIdentifier]
            XCTAssertNotNil(actualEvent, "Stored event identifier in SyncState must match an actual calendar event")
            XCTAssertEqual(actualEvent?.title, stored.title)
            let expectedURL = primaryEventURL(for: key)
            XCTAssertEqual(actualEvent?.url, expectedURL, "Actual event URL must match key URL")
        }
    }
}
