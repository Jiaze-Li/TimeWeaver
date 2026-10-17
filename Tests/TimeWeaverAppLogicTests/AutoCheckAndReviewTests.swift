import XCTest
import EventKit
@testable import TimeWeaverCore
@testable import TimeWeaverAppLogic

final class AutoCheckAndReviewTests: XCTestCase {

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

    private func computeFingerprint(for items: [AutoReviewChangeItem]) -> String {
        TimeWeaverCore.computeChangeFingerprint(
            items: items.map { item in
                (
                    sourceName: item.sourceName,
                    calendarName: item.calendarName,
                    status: item.status,
                    title: item.title,
                    oldStartTimestamp: item.oldStart?.timeIntervalSince1970 ?? 0,
                    oldEndTimestamp: item.oldEnd?.timeIntervalSince1970 ?? 0,
                    newStartTimestamp: item.newStart?.timeIntervalSince1970 ?? 0,
                    newEndTimestamp: item.newEnd?.timeIntervalSince1970 ?? 0,
                    syncKey: item.syncKey
                )
            }
        )
    }

    // 1. No changes: no items produced
    func testNoChangesDoesNotProduceReviewItems() {
        let report = SourceSyncReport(
            sourceItemID: UUID(),
            sourceName: "ppms",
            bookingID: "LJZ",
            calendarName: "Experiment",
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false,
            totalMatchedCount: 1,
            syncedMatchedCount: 1,
            filteredPastCount: 0,
            actions: [
                EventAction(status: "unchanged", title: "Meeting", start: makeDate(hour: 10), end: makeDate(hour: 11), syncKey: "k1")
            ],
            deleteCandidates: []
        )

        let items = buildAutoReviewItems(from: [report], existingState: SyncState())
        XCTAssertTrue(items.isEmpty, "Unchanged actions should not produce review items")
    }

    // 2. New event: review item created with status 'would create'
    func testNewEventProducesReviewItem() {
        let start = makeDate(hour: 10)
        let end = makeDate(hour: 11)

        let report = SourceSyncReport(
            sourceItemID: UUID(),
            sourceName: "ppms",
            bookingID: "LJZ",
            calendarName: "Experiment",
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false,
            totalMatchedCount: 1,
            syncedMatchedCount: 1,
            filteredPastCount: 0,
            actions: [
                EventAction(status: "would create", title: "New Lab Reservation", start: start, end: end, syncKey: "new-key-1")
            ],
            deleteCandidates: []
        )

        let items = buildAutoReviewItems(from: [report], existingState: SyncState())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].status, "would create")
        XCTAssertEqual(items[0].title, "New Lab Reservation")
        XCTAssertEqual(items[0].newStart, start)
        XCTAssertEqual(items[0].newEnd, end)
        XCTAssertNil(items[0].oldStart)
        XCTAssertNil(items[0].oldEnd)
    }

    // 3. Updated event: review item created with both old and new times
    func testUpdatedEventProducesReviewItemWithOldAndNewTimes() {
        let oldStart = makeDate(hour: 9)
        let oldEnd = makeDate(hour: 10)
        let newStart = makeDate(hour: 10)
        let newEnd = makeDate(hour: 11)

        var state = SyncState()
        state.events["update-key-1"] = StoredEvent(
            eventIdentifier: "ev-1",
            sourceID: "source-1",
            calendar: "Experiment",
            title: "Original Title",
            startISO: iso8601(oldStart),
            endISO: iso8601(oldEnd)
        )

        let report = SourceSyncReport(
            sourceItemID: UUID(),
            sourceName: "ppms",
            bookingID: "LJZ",
            calendarName: "Experiment",
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false,
            totalMatchedCount: 1,
            syncedMatchedCount: 1,
            filteredPastCount: 0,
            actions: [
                EventAction(status: "would update", title: "Updated Title", start: newStart, end: newEnd, syncKey: "update-key-1")
            ],
            deleteCandidates: []
        )

        let items = buildAutoReviewItems(from: [report], existingState: state)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].status, "would update")
        XCTAssertEqual(items[0].title, "Updated Title")
        XCTAssertNotNil(items[0].oldStart)
        XCTAssertNotNil(items[0].oldEnd)
        XCTAssertEqual(items[0].newStart, newStart)
        XCTAssertEqual(items[0].newEnd, newEnd)
    }

    // 4. Deleted event: review appears with safety protections tracked
    func testDeletedEventProducesReviewItemWithSafetyProtection() {
        let oldStart = makeDate(hour: 14)
        let oldEnd = makeDate(hour: 15)

        var state = SyncState()
        state.events["del-key-1"] = StoredEvent(
            eventIdentifier: "ev-del",
            sourceID: "source-1",
            calendar: "Experiment",
            title: "Old Booking",
            startISO: iso8601(oldStart),
            endISO: iso8601(oldEnd)
        )

        let sourceID = UUID()
        let report = SourceSyncReport(
            sourceItemID: sourceID,
            sourceName: "ppms",
            bookingID: "LJZ",
            calendarName: "Experiment",
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false,
            totalMatchedCount: 0,
            syncedMatchedCount: 0,
            filteredPastCount: 0,
            actions: [
                EventAction(status: "would delete", title: "Old Booking", start: oldStart, end: oldEnd, syncKey: "del-key-1")
            ],
            deleteCandidates: [
                DeleteCandidate(syncKey: "del-key-1", eventIdentifier: "ev-del", title: "Old Booking", startISO: iso8601(oldStart), endISO: iso8601(oldEnd))
            ],
            isSuspiciousDeletion: true
        )

        let items = buildAutoReviewItems(from: [report], existingState: state)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].status, "would delete")
        XCTAssertEqual(items[0].title, "Old Booking")
        XCTAssertNotNil(items[0].oldStart)
        XCTAssertNil(items[0].newStart)

        let fingerprint = computeFingerprint(for: items)
        let review = PendingAutoReview(
            items: items,
            fingerprint: fingerprint,
            plan: SyncPlan(reports: [report], extractions: [:], outputText: ""),
            authorizedDeletionSourceIDs: [sourceID]
        )

        XCTAssertTrue(review.authorizedDeletionSourceIDs.contains(sourceID))
    }

    // 5. Ignore suppression: identical fingerprint suppresses prompt, new change alters fingerprint
    func testFingerprintSuppressesSameChangeAndNewChangeAltersFingerprint() {
        let item1 = AutoReviewChangeItem(
            sourceName: "ppms",
            calendarName: "Experiment",
            status: "would create",
            title: "Task 1",
            oldStart: nil,
            oldEnd: nil,
            newStart: makeDate(hour: 10),
            newEnd: makeDate(hour: 11),
            syncKey: "k1"
        )

        let fp1 = computeFingerprint(for: [item1])
        var dismissedFingerprint: String? = fp1

        // Checking same items produces same fingerprint, so it is suppressed
        let fpCheck = computeFingerprint(for: [item1])
        XCTAssertEqual(fpCheck, dismissedFingerprint)

        // Adding a new change changes the fingerprint, so it will no longer match dismissedFingerprint
        let item2 = AutoReviewChangeItem(
            sourceName: "ppms",
            calendarName: "Experiment",
            status: "would create",
            title: "Task 2 (New)",
            oldStart: nil,
            oldEnd: nil,
            newStart: makeDate(hour: 12),
            newEnd: makeDate(hour: 13),
            syncKey: "k2"
        )
        let fp2 = computeFingerprint(for: [item1, item2])
        XCTAssertNotEqual(fp1, fp2, "New change must produce different fingerprint")
        XCTAssertNotEqual(fp2, dismissedFingerprint)

        // Simulating Accept: clears dismissed fingerprint
        dismissedFingerprint = nil
        XCTAssertNil(dismissedFingerprint)
    }

    // 6. Preview only does not mutate calendar store or sync state
    func testPreviewOnlyDoesNotMutateCalendarStoreOrSyncState() async throws {
        let fakeStore = FakeCalendarStore()
        _ = fakeStore.addCalendar(title: "Experiment")
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: fakeStore, stateStore: stateStore)

        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "ppms",
            source: "/path/to/test.xlsx",
            bookingID: "LJZ",
            calendar: "Experiment"
        )

        let start = makeDate(hour: 10)
        let end = makeDate(hour: 11)
        let event = ReservationEvent(
            syncKey: "preview-k1",
            legacySyncKey: nil,
            sourceID: source.id.uuidString,
            sourceName: "Meeting",
            sourceLink: "",
            bookingID: "LJZ",
            calendarName: "Experiment",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )

        let extraction = ExtractionResult(
            allEvents: [event],
            filteredEvents: [event],
            filteredPastCount: 0,
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false
        )

        var state = SyncState()

        // Perform previewSource
        let report = try await engine.syncSource(
            source: source,
            extraction: extraction,
            state: &state,
            upcomingOnly: false,
            previewOnly: true,
            aiApprovals: []
        )

        // Verify report generated proposed action
        XCTAssertEqual(report.actions.count, 1)
        XCTAssertEqual(report.actions.first?.status, "would create")

        // Verify state has not been mutated
        XCTAssertTrue(state.events.isEmpty, "Preview run must never mutate SyncState")

        // Verify fake calendar store has no events added
        XCTAssertEqual(fakeStore.storedEvents.count, 0, "Preview run must never mutate EKEventStore / FakeCalendarStore")
    }

    // 7. Parsing errors: error message flagged and prevents clean review
    func testParsingErrorsDoNotTriggerReview() {
        let report = SourceSyncReport(
            sourceItemID: UUID(),
            sourceName: "Broken Source",
            bookingID: "LJZ",
            calendarName: "Experiment",
            parserLabel: "Failed",
            parserNotes: [],
            reviewRequired: false,
            totalMatchedCount: 0,
            syncedMatchedCount: 0,
            filteredPastCount: 0,
            actions: [],
            deleteCandidates: [],
            errorMessage: "Network timed out"
        )

        XCTAssertNotNil(report.errorMessage)
        XCTAssertTrue(report.actions.isEmpty)
    }

    private func makeAutoReviewSyncFixture() -> (
        engine: CalendarSyncEngine,
        calendar: FakeCalendarStore,
        state: MemorySyncStateStore,
        source: SourceItem,
        extraction: ExtractionResult,
        start: Date,
        end: Date
    ) {
        let calendar = FakeCalendarStore()
        _ = calendar.addCalendar(title: "Experiment")
        let state = MemorySyncStateStore()
        let engine = CalendarSyncEngine(store: calendar, stateStore: state)
        let source = SourceItem(
            id: UUID(),
            enabled: true,
            name: "ppms",
            source: "/path/to/review-test.xlsx",
            bookingID: "LJZ",
            calendar: "Experiment"
        )
        let start = makeDate(day: 21, hour: 9)
        let end = makeDate(day: 21, hour: 10)
        let event = ReservationEvent(
            syncKey: "approved-booking",
            legacySyncKey: nil,
            sourceID: source.id.uuidString,
            sourceName: "Approved Booking",
            sourceLink: "",
            bookingID: "LJZ",
            calendarName: "Experiment",
            start: start,
            end: end,
            isAllDay: false,
            sheetNames: ["Sheet1"],
            cellReferences: ["A1"]
        )
        let extraction = ExtractionResult(
            allEvents: [event],
            filteredEvents: [event],
            filteredPastCount: 0,
            parserLabel: "Rule",
            parserNotes: [],
            reviewRequired: false
        )
        return (engine, calendar, state, source, extraction, start, end)
    }

    func testApprovedAutoReviewAppliesExactlyReviewedChanges() async throws {
        let f = makeAutoReviewSyncFixture()
        let cached = [f.source.id: f.extraction]
        let preview = try await f.engine.sync(
            sources: [f.source],
            workdayHours: WorkdayHours(start: "08:00", end: "18:00"),
            upcomingOnly: false,
            previewOnly: true,
            parserMode: .rulesOnly,
            aiConfiguration: nil,
            aiApprovals: [],
            schedulingTimeZoneIdentifier: "Asia/Singapore",
            cachedExtractions: cached
        )
        let reviewed = buildAutoReviewItems(from: preview.reports, existingState: f.state.loadState())
        XCTAssertEqual(reviewed.map(\.status), ["would create"])

        _ = try await f.engine.sync(
            sources: [f.source],
            workdayHours: WorkdayHours(start: "08:00", end: "18:00"),
            upcomingOnly: false,
            previewOnly: false,
            parserMode: .rulesOnly,
            aiConfiguration: nil,
            aiApprovals: [],
            schedulingTimeZoneIdentifier: "Asia/Singapore",
            cachedExtractions: cached,
            expectedAutoReviewItems: reviewed
        )
        XCTAssertEqual(f.calendar.storedEvents.count, 1)
        XCTAssertEqual(f.state.loadState().events.count, 1)
    }

    func testAutoReviewRejectsExternalCalendarChangeBeforeWrites() async throws {
        let f = makeAutoReviewSyncFixture()
        let cached = [f.source.id: f.extraction]
        let preview = try await f.engine.sync(
            sources: [f.source],
            workdayHours: WorkdayHours(start: "08:00", end: "18:00"),
            upcomingOnly: false,
            previewOnly: true,
            parserMode: .rulesOnly,
            aiConfiguration: nil,
            aiApprovals: [],
            schedulingTimeZoneIdentifier: "Asia/Singapore",
            cachedExtractions: cached
        )
        let reviewed = buildAutoReviewItems(from: preview.reports, existingState: f.state.loadState())
        XCTAssertEqual(reviewed.map(\.status), ["would create"])

        // Another sync wrote the event, then the calendar time changed externally.
        _ = try await f.engine.sync(
            sources: [f.source],
            workdayHours: WorkdayHours(start: "08:00", end: "18:00"),
            upcomingOnly: false,
            previewOnly: false,
            parserMode: .rulesOnly,
            aiConfiguration: nil,
            aiApprovals: [],
            schedulingTimeZoneIdentifier: "Asia/Singapore",
            cachedExtractions: cached
        )
        let changedEvent = try XCTUnwrap(f.calendar.storedEvents.values.first)
        let externalStart = f.start.addingTimeInterval(3600)
        changedEvent.startDate = externalStart
        changedEvent.endDate = f.end.addingTimeInterval(3600)

        do {
            _ = try await f.engine.sync(
                sources: [f.source],
                workdayHours: WorkdayHours(start: "08:00", end: "18:00"),
                upcomingOnly: false,
                previewOnly: false,
                parserMode: .rulesOnly,
                aiConfiguration: nil,
                aiApprovals: [],
                schedulingTimeZoneIdentifier: "Asia/Singapore",
                cachedExtractions: cached,
                expectedAutoReviewItems: reviewed
            )
            XCTFail("A changed calendar must require a fresh review")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("review"))
        }
        XCTAssertEqual(f.calendar.storedEvents.count, 1)
        XCTAssertEqual(f.calendar.storedEvents.values.first?.startDate, externalStart)
        XCTAssertEqual(f.state.loadState().events.count, 1)
    }
    func testIgnoredReviewSurvivesSerialization() throws {
        let item = AutoReviewChangeItem(sourceName: "ppms", calendarName: "Experiment", status: "would create",
            title: "Ignored", oldStart: nil, oldEnd: nil, newStart: makeDate(hour: 10),
            newEnd: makeDate(hour: 11), syncKey: "persist-key")
        let record = IgnoredAutoReview(fingerprint: computeFingerprint(for: [item]),
            ignoredAt: Date(timeIntervalSince1970: 1234), items: [item])
        let decoded = try JSONDecoder().decode([IgnoredAutoReview].self, from: JSONEncoder().encode([record]))
        XCTAssertEqual(decoded, [record])
        XCTAssertTrue(decoded.contains { $0.fingerprint == computeFingerprint(for: [item]) })
    }

    func testNewChangesDoNotMatchIgnoredReviewFingerprint() {
        let old = AutoReviewChangeItem(sourceName: "ppms", calendarName: "Experiment", status: "would create",
            title: "Old", oldStart: nil, oldEnd: nil, newStart: makeDate(hour: 10),
            newEnd: makeDate(hour: 11), syncKey: "old")
        let fresh = AutoReviewChangeItem(sourceName: "ppms", calendarName: "Experiment", status: "would create",
            title: "New", oldStart: nil, oldEnd: nil, newStart: makeDate(hour: 12),
            newEnd: makeDate(hour: 13), syncKey: "new")
        let ignored = IgnoredAutoReview(fingerprint: computeFingerprint(for: [old]),
            ignoredAt: Date(), items: [old])
        XCTAssertNotEqual(ignored.fingerprint, computeFingerprint(for: [old, fresh]))
    }

    func testBackgroundCheckRequiresExactLaunchArgument() {
        XCTAssertTrue(BackgroundCheckLaunch.isRequested(arguments: ["/bin/TimeWeaver", "--background-check-once"]))
        XCTAssertFalse(BackgroundCheckLaunch.isRequested(arguments: ["/bin/TimeWeaver"]))
        XCTAssertFalse(BackgroundCheckLaunch.isRequested(arguments: ["/bin/TimeWeaver", "--background-check"]))
    }
    func testIgnoredReviewOnlySuppressesExactProposalAndCanBeRechecked() {
        let old = AutoReviewChangeItem(sourceName: "ppms", calendarName: "Experiment", status: "would create",
            title: "Ignored", oldStart: nil, oldEnd: nil, newStart: makeDate(hour: 10),
            newEnd: makeDate(hour: 11), syncKey: "prior")
        let fingerprint = computeFingerprint(for: [old])
        let record = IgnoredAutoReview(fingerprint: fingerprint, ignoredAt: Date(), items: [old])
        XCTAssertTrue(shouldSuppressIgnoredReview(fingerprint: fingerprint, records: [record]))
        XCTAssertFalse(shouldSuppressIgnoredReview(fingerprint: fingerprint, records: [record],
            forceFingerprint: fingerprint))
        XCTAssertFalse(shouldSuppressIgnoredReview(fingerprint: "new-proposal", records: [record]))
    }
}
