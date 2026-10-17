import XCTest
import TimeWeaverCore
@testable import TimeWeaverAppLogic

final class SourceIdentityTests: XCTestCase {
    func testStableIdentityPreservedAcrossAttributeChanges() {
        var source = SourceItem(
            name: "Original Name",
            source: "https://example.com/sheet",
            bookingID: "LJZ",
            calendar: "Work"
        )
        let stableID = source.stableIdentity

        // Rename source
        source.name = "Renamed Microscope"
        XCTAssertEqual(source.stableIdentity, stableID, "Source rename must not change stable identity")

        // Change booking ID
        source.bookingID = "LJZ, EXP2"
        XCTAssertEqual(source.stableIdentity, stableID, "Booking ID change must not change stable identity")

        // Change calendar
        source.calendar = "Personal"
        XCTAssertEqual(source.stableIdentity, stableID, "Calendar change must not change stable identity")
    }

    func testLegacyIdentityMatchesDigest() {
        let source = SourceItem(
            name: "Test Source",
            source: "https://example.com/sheet",
            bookingID: "USER123",
            calendar: "Work"
        )
        let expectedLegacy = TimeWeaverCore.fnv1a64Hex("Test Source|https://example.com/sheet|USER123|Work")
        XCTAssertEqual(source.legacyIdentity, expectedLegacy)
    }

    func testLegacyJSONWithoutIDDecodesSafely() throws {
        let legacyJSON = """
        {
            "enabled": true,
            "name": "Legacy Source",
            "source": "https://example.com/legacy",
            "bookingID": "LEGACY",
            "calendar": "Work"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SourceItem.self, from: legacyJSON)
        XCTAssertEqual(decoded.name, "Legacy Source")
        XCTAssertEqual(decoded.bookingID, "LEGACY")
        XCTAssertFalse(decoded.stableIdentity.isEmpty)
    }

    func testEventOverrideRoundtrip() throws {
        let override = EventOverride(
            title: "Manual Title",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600)
        )
        let data = try JSONEncoder().encode(override)
        let decoded = try JSONDecoder().decode(EventOverride.self, from: data)
        XCTAssertEqual(decoded.title, "Manual Title")
        XCTAssertEqual(decoded.start, override.start)
        XCTAssertEqual(decoded.end, override.end)
    }

    func testImageImportEventEntryTracksOriginals() {
        let syncKey = "test-sync-key-123"
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_003_600)

        var entry = ImageImportEventEntry(
            syncKey: syncKey,
            title: "Original Title",
            originalTitle: "Original Title",
            start: start,
            end: end,
            status: "would create"
        )

        XCTAssertEqual(entry.id, syncKey)
        XCTAssertEqual(entry.originalStart, start)
        XCTAssertEqual(entry.originalEnd, end)

        // Modify fields as user does in review sheet
        entry.title = "Modified Title"
        entry.start = start.addingTimeInterval(1800)
        entry.end = end.addingTimeInterval(3600)

        XCTAssertEqual(entry.id, syncKey, "ID must remain stable even after editing start/end/title")
        XCTAssertNotEqual(entry.title, entry.originalTitle)
        XCTAssertNotEqual(entry.start, entry.originalStart)
        XCTAssertNotEqual(entry.end, entry.originalEnd)
    }
}
