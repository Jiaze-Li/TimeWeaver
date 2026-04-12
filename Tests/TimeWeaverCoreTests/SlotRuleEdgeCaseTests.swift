import XCTest
@testable import TimeWeaverCore

final class SlotRuleEdgeCaseTests: XCTestCase {

    // MARK: - parseSlotRange edge cases

    func testParseSlotRange12am() {
        let result = TimeWeaverCore.parseSlotRange(from: "12am-6am")
        XCTAssertEqual(result?.start, "00:00")
        XCTAssertEqual(result?.end, "06:00")
        XCTAssertEqual(result?.endsNextDay, false)
    }

    func testParseSlotRange12pm() {
        let result = TimeWeaverCore.parseSlotRange(from: "12pm-3pm")
        XCTAssertEqual(result?.start, "12:00")
        XCTAssertEqual(result?.end, "15:00")
        XCTAssertEqual(result?.endsNextDay, false)
    }

    func testParseSlotRangeWithMinutes() {
        let result = TimeWeaverCore.parseSlotRange(from: "8:30-13:45")
        XCTAssertEqual(result?.start, "08:30")
        XCTAssertEqual(result?.end, "13:45")
    }

    func testParseSlotRangeEmDash() {
        let result = TimeWeaverCore.parseSlotRange(from: "9:00\u{2014}17:00")
        XCTAssertEqual(result?.start, "09:00")
        XCTAssertEqual(result?.end, "17:00")
    }

    func testParseSlotRangeWithSpaces() {
        let result = TimeWeaverCore.parseSlotRange(from: "10 : 00 - 14 : 00")
        // spaces are stripped, should still parse
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, "10:00")
        XCTAssertEqual(result?.end, "14:00")
    }

    func testParseSlotRangeSingleDigitHours() {
        let result = TimeWeaverCore.parseSlotRange(from: "9-5")
        XCTAssertNotNil(result)
        // Ambiguous: could be 9am-5pm (8h) or 9am-5am (20h). Prefers shorter.
        XCTAssertEqual(result?.start, "09:00")
        XCTAssertEqual(result?.end, "17:00")
    }

    func testParseSlotRangeRejectsInvalidHour() {
        XCTAssertNil(TimeWeaverCore.parseSlotRange(from: "25:00-26:00"))
    }

    func testParseSlotRangeRejectsInvalidMinute() {
        XCTAssertNil(TimeWeaverCore.parseSlotRange(from: "10:99-12:00"))
    }

    func testParseSlotRangeRejectsSingleValue() {
        XCTAssertNil(TimeWeaverCore.parseSlotRange(from: "10:00"))
    }

    // MARK: - inferredSlotRule edge cases

    func testInferredSlotRuleTrimsWhitespace() {
        let rules = [TimeWeaverCore.SlotRule(sheetLabel: "morning", start: "08:00", end: "12:00", endsNextDay: false)]
        let result = TimeWeaverCore.inferredSlotRule(from: "  morning  ", builtinRules: rules)
        XCTAssertEqual(result?.start, "08:00")
    }

    func testInferredSlotRuleNoMatchFallsThroughToRange() {
        let rules = [TimeWeaverCore.SlotRule(sheetLabel: "morning", start: "08:00", end: "12:00", endsNextDay: false)]
        let result = TimeWeaverCore.inferredSlotRule(from: "14:00-18:00", builtinRules: rules)
        XCTAssertEqual(result?.start, "14:00")
        XCTAssertEqual(result?.end, "18:00")
    }

    func testInferredSlotRuleUnmatchedNonRangeReturnsNil() {
        let rules = [TimeWeaverCore.SlotRule(sheetLabel: "morning", start: "08:00", end: "12:00", endsNextDay: false)]
        XCTAssertNil(TimeWeaverCore.inferredSlotRule(from: "afternoon", builtinRules: rules))
    }

    // MARK: - shouldDeleteTrackedEvent edge cases

    func testShouldDeleteTrackedEventDifferentSourceSkips() {
        let now = Date(timeIntervalSince1970: 1_735_750_400)
        let result = TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "source-a",
            requestedSourceID: "source-b",
            syncKey: "k1",
            activeSyncKeys: [],
            trackedStartISO: "2025-01-02T10:00:00Z",
            upcomingOnly: false,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertFalse(result)
    }

    func testShouldDeleteTrackedEventFullModeDeletesAll() {
        let now = Date(timeIntervalSince1970: 1_735_750_400)
        let result = TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "source-a",
            requestedSourceID: "source-a",
            syncKey: "k1",
            activeSyncKeys: [],
            trackedStartISO: "2024-01-01T10:00:00Z",
            upcomingOnly: false,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(result)
    }

    func testShouldDeleteTrackedEventInvalidISOKeepsPast() {
        let now = Date(timeIntervalSince1970: 1_735_750_400)
        let result = TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "source-a",
            requestedSourceID: "source-a",
            syncKey: "k1",
            activeSyncKeys: [],
            trackedStartISO: "not-a-date",
            upcomingOnly: true,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertFalse(result)
    }

    // MARK: - fnv1a64Hex

    func testFnv1aEmptyString() {
        let hash = TimeWeaverCore.fnv1a64Hex("")
        XCTAssertEqual(hash.count, 16, "FNV-1a hash should be 16 hex chars")
    }

    func testFnv1aDifferentInputsDifferentHashes() {
        let h1 = TimeWeaverCore.fnv1a64Hex("hello")
        let h2 = TimeWeaverCore.fnv1a64Hex("world")
        XCTAssertNotEqual(h1, h2)
    }
}
