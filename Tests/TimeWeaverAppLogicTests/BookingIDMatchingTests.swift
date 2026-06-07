import XCTest
@testable import TimeWeaverAppLogic

final class BookingIDMatchingTests: XCTestCase {
    private func source(_ bookingID: String) -> SourceItem {
        SourceItem(name: "n", source: "s", bookingID: bookingID, calendar: "c")
    }

    func testSingleIDBehaviorUnchanged() {
        let item = source("LJZ")
        XCTAssertEqual(item.bookingIDs, ["LJZ"])
        XCTAssertTrue(item.matchesBookingID("LJZ"))
        XCTAssertTrue(item.matchesBookingID("ljz"), "matching stays case-insensitive")
        XCTAssertFalse(item.matchesBookingID("ABC"))
    }

    func testMultipleIDsMatchAny() {
        let item = source("abc, def")
        XCTAssertEqual(item.bookingIDs, ["abc", "def"])
        XCTAssertTrue(item.matchesBookingID("abc"))
        XCTAssertTrue(item.matchesBookingID("DEF"))
        XCTAssertFalse(item.matchesBookingID("ghi"))
    }

    func testWhitespaceAndEmptySegmentsAreIgnored() {
        let item = source("  abc ,, def ,  ")
        XCTAssertEqual(item.bookingIDs, ["abc", "def"])
        XCTAssertTrue(item.matchesBookingID("abc"))
        XCTAssertTrue(item.matchesBookingID("def"))
    }

    func testEmptyBookingIDMatchesNothing() {
        let item = source("   ")
        XCTAssertEqual(item.bookingIDs, [])
        XCTAssertFalse(item.matchesBookingID(""))
        XCTAssertFalse(item.matchesBookingID("abc"))
    }
}
