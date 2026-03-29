import XCTest
@testable import TimeWeaverCore

final class SyncDecisionLogicTests: XCTestCase {
    func testChooseAutoParserStrategyFallsBackToRulesWhenMatched() {
        let strategy = TimeWeaverCore.chooseAutoParserStrategy(
            ruleOccurrencesCount: 4,
            hasAIConfiguration: false
        )
        XCTAssertEqual(strategy, .ruleBased)
    }

    func testChooseAutoParserStrategyUsesRulesWhenAIUnavailable() {
        let strategy = TimeWeaverCore.chooseAutoParserStrategy(
            ruleOccurrencesCount: 0,
            hasAIConfiguration: false
        )
        XCTAssertEqual(strategy, .ruleBasedNoAIConfiguration)
    }

    func testChooseAutoParserStrategyUsesAIWhenRulesMiss() {
        let strategy = TimeWeaverCore.chooseAutoParserStrategy(
            ruleOccurrencesCount: 0,
            hasAIConfiguration: true
        )
        XCTAssertEqual(strategy, .aiNormalization)
    }

    func testDetermineUpsertMutationCreate() {
        let mutation = TimeWeaverCore.determineUpsertMutation(
            hasExistingEvent: false,
            oldSignature: "",
            newSignature: "new"
        )
        XCTAssertEqual(mutation, .create)
    }

    func testDetermineUpsertMutationUpdate() {
        let mutation = TimeWeaverCore.determineUpsertMutation(
            hasExistingEvent: true,
            oldSignature: "old",
            newSignature: "new"
        )
        XCTAssertEqual(mutation, .update)
    }

    func testDetermineUpsertMutationUnchanged() {
        let mutation = TimeWeaverCore.determineUpsertMutation(
            hasExistingEvent: true,
            oldSignature: "same",
            newSignature: "same"
        )
        XCTAssertEqual(mutation, .unchanged)
    }

    func testShouldDeleteTrackedEventInUpcomingOnlyModeKeepsPastEvents() {
        let now = Date(timeIntervalSince1970: 1_735_750_400) // 2025-01-01T00:00:00Z
        let result = TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "source-a",
            requestedSourceID: "source-a",
            syncKey: "k1",
            activeSyncKeys: [],
            trackedStartISO: "2024-12-31T10:00:00Z",
            upcomingOnly: true,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertFalse(result)
    }

    func testShouldDeleteTrackedEventInUpcomingOnlyModeDeletesFutureEvents() {
        let now = Date(timeIntervalSince1970: 1_735_750_400) // 2025-01-01T00:00:00Z
        let result = TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "source-a",
            requestedSourceID: "source-a",
            syncKey: "k1",
            activeSyncKeys: [],
            trackedStartISO: "2025-01-02T10:00:00Z",
            upcomingOnly: true,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(result)
    }

    func testShouldDeleteTrackedEventSkipsActiveKeys() {
        let now = Date(timeIntervalSince1970: 1_735_750_400)
        let result = TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: "source-a",
            requestedSourceID: "source-a",
            syncKey: "k1",
            activeSyncKeys: ["k1"],
            trackedStartISO: "2025-01-02T10:00:00Z",
            upcomingOnly: false,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertFalse(result)
    }

    func testFingerprintHashIsDeterministic() {
        let sample = "sheet-a|row-1|row-2|booking-id"
        XCTAssertEqual(TimeWeaverCore.fnv1a64Hex(sample), TimeWeaverCore.fnv1a64Hex(sample))
    }

    func testFingerprintHashChangesWhenInputChanges() {
        XCTAssertNotEqual(TimeWeaverCore.fnv1a64Hex("abc"), TimeWeaverCore.fnv1a64Hex("abd"))
    }
}
