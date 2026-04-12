import XCTest
@testable import TimeWeaverCore

final class SlotRuleParserTests: XCTestCase {
    private let builtinRules = [
        TimeWeaverCore.SlotRule(sheetLabel: "8:30-1pm", start: "08:30", end: "13:00", endsNextDay: false),
        TimeWeaverCore.SlotRule(sheetLabel: "1pm-6pm", start: "13:00", end: "18:00", endsNextDay: false),
        TimeWeaverCore.SlotRule(sheetLabel: "overnight", start: "18:00", end: "08:30", endsNextDay: true),
    ]

    func testBuiltinLabelMatchesExactly() {
        let result = TimeWeaverCore.inferredSlotRule(from: "8:30-1pm", builtinRules: builtinRules)
        XCTAssertEqual(result?.start, "08:30")
        XCTAssertEqual(result?.end, "13:00")
        XCTAssertEqual(result?.endsNextDay, false)
    }

    func testBuiltinLabelMatchesCaseInsensitive() {
        let result = TimeWeaverCore.inferredSlotRule(from: "1PM-6PM", builtinRules: builtinRules)
        XCTAssertEqual(result?.start, "13:00")
        XCTAssertEqual(result?.end, "18:00")
    }

    func testBuiltinOvernightLabel() {
        let result = TimeWeaverCore.inferredSlotRule(from: "overnight", builtinRules: builtinRules)
        XCTAssertEqual(result?.start, "18:00")
        XCTAssertEqual(result?.end, "08:30")
        XCTAssertEqual(result?.endsNextDay, true)
    }

    func testParseSlotRange24Hour() {
        let result = TimeWeaverCore.parseSlotRange(from: "9:00-17:00")
        XCTAssertEqual(result?.start, "09:00")
        XCTAssertEqual(result?.end, "17:00")
        XCTAssertEqual(result?.endsNextDay, false)
    }

    func testParseSlotRangeAMPM() {
        let result = TimeWeaverCore.parseSlotRange(from: "9am-5pm")
        XCTAssertEqual(result?.start, "09:00")
        XCTAssertEqual(result?.end, "17:00")
        XCTAssertEqual(result?.endsNextDay, false)
    }

    func testParseSlotRangeCrossMidnight() {
        let result = TimeWeaverCore.parseSlotRange(from: "22:00-06:00")
        XCTAssertEqual(result?.start, "22:00")
        XCTAssertEqual(result?.end, "06:00")
        XCTAssertEqual(result?.endsNextDay, true)
    }

    func testParseSlotRangeWithEnDash() {
        let result = TimeWeaverCore.parseSlotRange(from: "10:00\u{2013}14:00")
        XCTAssertEqual(result?.start, "10:00")
        XCTAssertEqual(result?.end, "14:00")
    }

    func testParseSlotRangeWithTo() {
        let result = TimeWeaverCore.parseSlotRange(from: "8 to 12")
        XCTAssertEqual(result?.start, "08:00")
        XCTAssertEqual(result?.end, "12:00")
    }

    func testInferredSlotRuleFromDynamicRange() {
        let result = TimeWeaverCore.inferredSlotRule(from: "14:00-18:00", builtinRules: builtinRules)
        XCTAssertEqual(result?.start, "14:00")
        XCTAssertEqual(result?.end, "18:00")
        XCTAssertEqual(result?.endsNextDay, false)
    }

    func testEmptyLabelReturnsNil() {
        XCTAssertNil(TimeWeaverCore.inferredSlotRule(from: "", builtinRules: builtinRules))
        XCTAssertNil(TimeWeaverCore.inferredSlotRule(from: "   ", builtinRules: builtinRules))
    }

    func testGarbageInputReturnsNil() {
        XCTAssertNil(TimeWeaverCore.parseSlotRange(from: "hello"))
        XCTAssertNil(TimeWeaverCore.parseSlotRange(from: "abc-def"))
    }
}
