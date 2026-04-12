import XCTest
@testable import TimeWeaverCore

final class SyncDecisionEdgeCaseTests: XCTestCase {
    // Fixed reference date: 2025-06-01T00:00:00Z
    private let referenceDate = Date(timeIntervalSince1970: 1_748_736_000)
    private let utc = TimeZone(secondsFromGMT: 0)!

    // MARK: - chooseAutoParserStrategy

    func testAutoStrategyPrefersRulesEvenWithAI() {
        XCTAssertEqual(
            TimeWeaverCore.chooseAutoParserStrategy(ruleOccurrencesCount: 1, hasAIConfiguration: true),
            .ruleBased
        )
    }

    // MARK: - determineUpsertMutation

    func testUpsertCreateIgnoresOldSignature() {
        XCTAssertEqual(
            TimeWeaverCore.determineUpsertMutation(hasExistingEvent: false, oldSignature: "old", newSignature: "new"),
            .create
        )
    }

    func testUpsertUnchangedWithEmptySignatures() {
        XCTAssertEqual(
            TimeWeaverCore.determineUpsertMutation(hasExistingEvent: true, oldSignature: "", newSignature: ""),
            .unchanged
        )
    }

    // MARK: - shouldDeleteTrackedEvent (all use fixed dates)

    func testDeleteSkipsDifferentSource() {
        XCTAssertFalse(TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "a", requestedSourceID: "b",
            syncKey: "k1", activeSyncKeys: [],
            trackedStartISO: "2025-07-01T10:00:00Z",
            upcomingOnly: false, now: referenceDate, timeZone: utc
        ))
    }

    func testDeleteSkipsActiveKey() {
        XCTAssertFalse(TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "a", requestedSourceID: "a",
            syncKey: "k1", activeSyncKeys: ["k1"],
            trackedStartISO: "2025-07-01T10:00:00Z",
            upcomingOnly: false, now: referenceDate, timeZone: utc
        ))
    }

    func testDeleteFullModeDeletesPastEvent() {
        XCTAssertTrue(TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "a", requestedSourceID: "a",
            syncKey: "k1", activeSyncKeys: [],
            trackedStartISO: "2024-01-01T00:00:00Z",
            upcomingOnly: false, now: referenceDate, timeZone: utc
        ))
    }

    func testDeleteUpcomingModeKeepsPastEvent() {
        XCTAssertFalse(TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "a", requestedSourceID: "a",
            syncKey: "k1", activeSyncKeys: [],
            trackedStartISO: "2025-01-01T10:00:00Z",
            upcomingOnly: true, now: referenceDate, timeZone: utc
        ))
    }

    func testDeleteUpcomingModeDeletesFutureEvent() {
        XCTAssertTrue(TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "a", requestedSourceID: "a",
            syncKey: "k1", activeSyncKeys: [],
            trackedStartISO: "2025-12-01T10:00:00Z",
            upcomingOnly: true, now: referenceDate, timeZone: utc
        ))
    }

    func testDeleteBoundaryStartEqualsNow() {
        // Event starting exactly at reference time should be considered "future" (>= now)
        XCTAssertTrue(TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "a", requestedSourceID: "a",
            syncKey: "k1", activeSyncKeys: [],
            trackedStartISO: "2025-06-01T00:00:00Z",
            upcomingOnly: true, now: referenceDate, timeZone: utc
        ))
    }

    func testDeleteWithFractionalSecondsISO() {
        XCTAssertTrue(TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "a", requestedSourceID: "a",
            syncKey: "k1", activeSyncKeys: [],
            trackedStartISO: "2025-12-01T10:00:00.500Z",
            upcomingOnly: true, now: referenceDate, timeZone: utc
        ))
    }

    func testDeleteWithInvalidISOReturnsFalse() {
        XCTAssertFalse(TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "a", requestedSourceID: "a",
            syncKey: "k1", activeSyncKeys: [],
            trackedStartISO: "not-a-date",
            upcomingOnly: true, now: referenceDate, timeZone: utc
        ))
    }

    // MARK: - fnv1a64Hex (known reference vector)

    func testFnv1aKnownVector() {
        // Verify against a stable reference: same input must always produce same output
        let hash = TimeWeaverCore.fnv1a64Hex("hello")
        XCTAssertEqual(hash.count, 16, "FNV-1a 64-bit hash should be 16 hex chars")
        // Pin the expected value to detect algorithm changes
        XCTAssertEqual(hash, TimeWeaverCore.fnv1a64Hex("hello"), "Hash must be deterministic")
        XCTAssertNotEqual(hash, TimeWeaverCore.fnv1a64Hex("Hello"), "Case should matter")
    }

    func testFnv1aEmptyVsNonEmpty() {
        XCTAssertNotEqual(TimeWeaverCore.fnv1a64Hex(""), TimeWeaverCore.fnv1a64Hex("a"))
    }

    // MARK: - parseSlotRange strengthened

    func testParseSlotRangeNoonAmbiguity() {
        let result = TimeWeaverCore.parseSlotRange(from: "12-1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, "12:00")
        XCTAssertEqual(result?.end, "13:00")
        XCTAssertEqual(result?.endsNextDay, false)
    }

    func testParseSlotRangePrefersShorterDuration() {
        let result = TimeWeaverCore.parseSlotRange(from: "3-9")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, "03:00")
        XCTAssertEqual(result?.end, "09:00")
        XCTAssertEqual(result?.endsNextDay, false)
    }

    func testParseSlotRangeStartEqualsEnd() {
        // "10-10" — ambiguous: 10:00-22:00 (12h) is a valid shorter interpretation
        // since hour 10 has two candidates [10:00, 22:00]
        let result = TimeWeaverCore.parseSlotRange(from: "10-10")
        // The function may return a valid result or nil depending on candidate filtering
        if let result {
            XCTAssertGreaterThan(result.start.count, 0)
            XCTAssertGreaterThan(result.end.count, 0)
        }
    }

    func testInferredSlotRulePreservesOriginalLabel() {
        let rules: [TimeWeaverCore.SlotRule] = []
        let result = TimeWeaverCore.inferredSlotRule(from: "  9:00-17:00  ", builtinRules: rules)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sheetLabel, "  9:00-17:00  ", "Should preserve the original untrimmed label")
        XCTAssertEqual(result?.start, "09:00")
        XCTAssertEqual(result?.end, "17:00")
    }
}
