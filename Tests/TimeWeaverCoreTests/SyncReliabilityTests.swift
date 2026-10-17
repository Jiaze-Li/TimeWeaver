import XCTest
@testable import TimeWeaverCore

final class SyncReliabilityTests: XCTestCase {
    func testLegacySourceIdentityVulnerableToRenames() {
        // Demonstrates P1: Legacy Source Identity Instability
        let initialLegacy = TimeWeaverCore.fnv1a64Hex("Lab Microscope|https://example.com/sheet|LJZ|Work")
        let renamedLegacy = TimeWeaverCore.fnv1a64Hex("Zeiss Microscope|https://example.com/sheet|LJZ|Work")
        let bookingIDChangedLegacy = TimeWeaverCore.fnv1a64Hex("Lab Microscope|https://example.com/sheet|LJZ, EXP2|Work")
        let calendarChangedLegacy = TimeWeaverCore.fnv1a64Hex("Lab Microscope|https://example.com/sheet|LJZ|Personal")

        // None of the legacy IDs match when user edits the source
        XCTAssertNotEqual(initialLegacy, renamedLegacy)
        XCTAssertNotEqual(initialLegacy, bookingIDChangedLegacy)
        XCTAssertNotEqual(initialLegacy, calendarChangedLegacy)

        // Without migration support, shouldDeleteTrackedEvent with renamed source fails to match old events
        let unmigratedDelete = TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: initialLegacy,
            requestedSourceID: renamedLegacy,
            legacySourceID: nil,
            syncKey: "key-1",
            activeSyncKeys: [],
            trackedStartISO: "2026-11-01T10:00:00Z",
            upcomingOnly: true,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: .current
        )
        XCTAssertFalse(unmigratedDelete, "Unmigrated rename fails to match old source events")
    }

    func testStableSourceIdentityMatchesAcrossRenamesAndEdits() {
        // Fix verification: stable UUID string matches consistently
        let stableID = "88888888-4444-4444-4444-121212121212"
        let legacyID = TimeWeaverCore.fnv1a64Hex("Old Name|https://example.com|LJZ|Work")

        // Matches with stable ID
        XCTAssertTrue(TimeWeaverCore.matchesSourceIdentity(
            trackedSourceID: stableID,
            currentSourceID: stableID,
            legacySourceID: legacyID
        ))

        // Matches legacy ID for historical events
        XCTAssertTrue(TimeWeaverCore.matchesSourceIdentity(
            trackedSourceID: legacyID,
            currentSourceID: stableID,
            legacySourceID: legacyID
        ))

        // Rejects mismatched unrelated sources
        XCTAssertFalse(TimeWeaverCore.matchesSourceIdentity(
            trackedSourceID: "unrelated-source-uuid",
            currentSourceID: stableID,
            legacySourceID: legacyID
        ))

        // shouldDeleteTrackedEvent successfully tracks historical events via legacySourceID
        let shouldDelete = TimeWeaverCore.shouldDeleteTrackedEvent(
            trackedSourceID: legacyID,
            requestedSourceID: stableID,
            legacySourceID: legacyID,
            syncKey: "old-event-key",
            activeSyncKeys: [],
            trackedStartISO: "2026-11-01T10:00:00Z",
            upcomingOnly: true,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: .current
        )
        XCTAssertTrue(shouldDelete, "Legacy events are safely tracked and cleaned up under stable source identity")
    }

    func testSuspiciousDeletionDetection() {
        // P1 Fix verification: empty parse results when events are tracked are flagged as suspicious
        XCTAssertTrue(
            TimeWeaverCore.isDeletionSuspicious(trackedCount: 10, extractedCount: 0, reviewRequired: false),
            "10 scheduled events disappearing completely should be flagged as suspicious deletion"
        )

        // Review-required AI extractions with tracked events are flagged as suspicious
        XCTAssertTrue(
            TimeWeaverCore.isDeletionSuspicious(trackedCount: 5, extractedCount: 3, reviewRequired: true),
            "Low-confidence AI extractions must be flagged before removing tracked events"
        )

        // Normal cancellation (e.g. 5 tracked, 4 extracted) is NOT suspicious
        XCTAssertFalse(
            TimeWeaverCore.isDeletionSuspicious(trackedCount: 5, extractedCount: 4, reviewRequired: false),
            "Normal single cancellation is expected and not suspicious"
        )

        // Zero tracked events is not suspicious
        XCTAssertFalse(
            TimeWeaverCore.isDeletionSuspicious(trackedCount: 0, extractedCount: 0, reviewRequired: false)
        )
    }

    func testTimeIntervalValidation() {
        // P1 Fix verification: validate start < end
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_003_600)
        let equal = Date(timeIntervalSince1970: 1_000_000)
        let inverted = Date(timeIntervalSince1970: 900_000)

        XCTAssertTrue(TimeWeaverCore.validateTimeInterval(start: start, end: end))
        XCTAssertFalse(TimeWeaverCore.validateTimeInterval(start: start, end: equal), "Zero duration is invalid")
        XCTAssertFalse(TimeWeaverCore.validateTimeInterval(start: start, end: inverted), "End before start is invalid")
    }
}
