import Foundation

let defaultSchedulingTimeZoneIdentifier = "Asia/Singapore"

func builtinSlotRules() -> [SlotRule] {
    [
        SlotRule(sheetLabel: "8:30-1pm", start: "08:30", end: "13:00", endsNextDay: false),
        SlotRule(sheetLabel: "1pm-6pm", start: "13:00", end: "18:00", endsNextDay: false),
        SlotRule(sheetLabel: "overnight", start: "18:00", end: "08:30", endsNextDay: true),
    ]
}

func defaultWorkdayHours() -> WorkdayHours {
    WorkdayHours(start: "10:00", end: "20:00")
}

func defaultSources() -> [SourceItem] {
    [
        SourceItem(
            name: "ppms",
            source: "https://docs.google.com/spreadsheets/d/1J7XCLh20n1qBkhBNyfF0XwnM2vItuOlGl6j5iQR1aVg/edit?usp=sharing",
            bookingID: "LJZ",
            calendar: "Experiment"
        )
    ]
}
