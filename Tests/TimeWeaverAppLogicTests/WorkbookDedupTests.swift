import XCTest
import EventKit
@testable import TimeWeaverCore
@testable import TimeWeaverAppLogic

/// Builds minimal xlsx fixtures and a counting fake downloader so workbook reuse can be observed
/// without any network access.
private final class FakeWorkbookDownloader: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: URL] = [:]
    private var failing: Set<String> = []
    private(set) var downloadCounts: [String: Int] = [:]
    private(set) var returnedFiles: [URL] = []

    func setFixture(_ url: URL, for id: String) {
        lock.lock(); defer { lock.unlock() }
        fixtures[id] = url
    }

    func setFailing(_ id: String, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if value { failing.insert(id) } else { failing.remove(id) }
    }

    var totalDownloads: Int {
        lock.lock(); defer { lock.unlock() }
        return downloadCounts.values.reduce(0, +)
    }

    func downloadCount(for id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return downloadCounts[id] ?? 0
    }

    func download(_ source: String) async throws -> URL {
        let id = source.components(separatedBy: "/d/").last?.components(separatedBy: "/").first ?? source
        lock.lock()
        downloadCounts[id, default: 0] += 1
        let fixture = fixtures[id]
        let shouldFail = failing.contains(id)
        lock.unlock()
        if shouldFail { throw AppFailure.syncFailed("fake download failure for \(id)") }
        guard let fixture else { throw AppFailure.invalidSource }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeweaver-test-dl-\(UUID().uuidString).xlsx")
        try FileManager.default.copyItem(at: fixture, to: copy)
        lock.lock(); returnedFiles.append(copy); lock.unlock()
        return copy
    }
}

private struct FixtureSheet {
    var name: String
    /// (column letter, day number) pairs on row 1, followed by (row, label) in column A and cells.
    var days: [(String, Int)]
    var slotLabels: [(Int, String)]
    var bookings: [(String, String)] // cell reference -> booking id
}

private func makeWorkbook(_ sheets: [FixtureSheet], in directory: URL) throws -> URL {
    let root = directory.appendingPathComponent("wb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)

    var sheetEntries = ""
    var relEntries = ""
    for (index, sheet) in sheets.enumerated() {
        let n = index + 1
        sheetEntries += "<sheet name=\"\(sheet.name)\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
        relEntries += "<Relationship Id=\"rId\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"

        var rows = "<row r=\"1\">"
        for (column, day) in sheet.days { rows += "<c r=\"\(column)1\"><v>\(day)</v></c>" }
        rows += "</row>"
        for (row, label) in sheet.slotLabels {
            rows += "<row r=\"\(row)\"><c r=\"A\(row)\" t=\"inlineStr\"><is><t>\(label)</t></is></c>"
            for (reference, id) in sheet.bookings where Int(reference.drop { $0.isLetter }) == row {
                rows += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(id)</t></is></c>"
            }
            rows += "</row>"
        }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>"
        try xml.write(to: root.appendingPathComponent("xl/worksheets/sheet\(n).xml"), atomically: true, encoding: .utf8)
    }
    let workbookXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetEntries)</sheets></workbook>"
    try workbookXML.write(to: root.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
    let relsXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relEntries)</Relationships>"
    try relsXML.write(to: root.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)

    let output = directory.appendingPathComponent("fixture-\(UUID().uuidString).xlsx")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = root
    zip.arguments = ["-qr", output.path, "."]
    try zip.run()
    zip.waitUntilExit()
    XCTAssertEqual(zip.terminationStatus, 0)
    return output
}

/// Standard future fixture: Oct 2090 days 5 and 6, two bookings (BK-1 on day 5 afternoon, BK-2 on day 6 morning).
private func standardSheets() -> [FixtureSheet] {
    [FixtureSheet(
        name: "Oct 2090",
        days: [("B", 5), ("C", 6)],
        slotLabels: [(2, "8:30-1pm"), (3, "1pm-6pm"), (4, "overnight")],
        bookings: [("B3", "BK-1"), ("C2", "BK-2")]
    )]
}

final class WorkbookDedupTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeweaver-dedup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func sheetURL(_ id: String, gid: Int = 0) -> String {
        "https://docs.google.com/spreadsheets/d/\(id)/edit?gid=\(gid)"
    }

    private func makeEngine(
        _ downloader: FakeWorkbookDownloader,
        calendars: [String] = ["Default"]
    ) -> (CalendarSyncEngine, FakeCalendarStore, MemorySyncStateStore) {
        let store = FakeCalendarStore()
        for title in calendars { _ = store.addCalendar(title: title) }
        let stateStore = MemorySyncStateStore()
        let engine = CalendarSyncEngine(
            store: store,
            stateStore: stateStore,
            workbookDownloader: { try await downloader.download($0) }
        )
        return (engine, store, stateStore)
    }

    private func run(
        _ engine: CalendarSyncEngine,
        sources: [SourceItem],
        previewOnly: Bool = true,
        upcomingOnly: Bool = true,
        authorizedDeletionSourceIDs: Set<UUID> = []
    ) async throws -> SyncRunResult {
        try await engine.sync(
            sources: sources,
            workdayHours: WorkdayHours(start: "10:00", end: "20:00"),
            upcomingOnly: upcomingOnly,
            previewOnly: previewOnly,
            parserMode: .rulesOnly,
            aiConfiguration: nil,
            aiApprovals: [],
            schedulingTimeZoneIdentifier: "Asia/Singapore",
            authorizedDeletionSourceIDs: authorizedDeletionSourceIDs
        )
    }

    private func source(_ name: String, _ url: String, _ booking: String, calendar: String = "Default") -> SourceItem {
        SourceItem(name: name, source: url, bookingID: booking, calendar: calendar)
    }

    private func fingerprint(_ result: SyncRunResult) -> [[String]] {
        result.reports.map { report in
            report.actions.map { "\($0.status)|\($0.title)|\($0.start.timeIntervalSince1970)|\($0.end.timeIntervalSince1970)|\($0.syncKey)" }
                + report.deleteCandidates.map { "del|\($0.syncKey)" }
                + ["total=\(report.totalMatchedCount)", "future=\(report.syncedMatchedCount)", "past=\(report.filteredPastCount)"]
        }
    }

    // 1. Same workbook, different booking IDs: one read, independent extraction.
    func testSameWorkbookDifferentBookingIDsReadsOnceButExtractsIndependently() async throws {
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(standardSheets(), in: tempDirectory), for: "AAA")
        let (engine, _, _) = makeEngine(downloader)
        let one = source("One", sheetURL("AAA", gid: 1), "BK-1")
        let two = source("Two", sheetURL("AAA", gid: 7), "BK-2")

        let result = try await run(engine, sources: [one, two])

        XCTAssertEqual(downloader.downloadCount(for: "AAA"), 1)
        XCTAssertEqual(result.reports.count, 2)
        XCTAssertEqual(result.reports[0].totalMatchedCount, 1)
        XCTAssertEqual(result.reports[1].totalMatchedCount, 1)
        XCTAssertNotEqual(result.reports[0].actions.first?.syncKey, result.reports[1].actions.first?.syncKey)
        XCTAssertNotEqual(result.reports[0].actions.first?.start, result.reports[1].actions.first?.start)
        XCTAssertTrue(result.outputText.contains("Workbooks: 1 read (1 downloaded, 1 parsed), 1 reused"), result.outputText)
        XCTAssertTrue(result.outputText.contains("workbook reused from earlier source"))
        for file in downloader.returnedFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "temporary download must be removed")
        }
    }

    // 2. Same workbook, different calendars: results stay per Source.
    func testSameWorkbookDifferentCalendarsKeepsSourcesIndependent() async throws {
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(standardSheets(), in: tempDirectory), for: "AAA")
        let (engine, store, _) = makeEngine(downloader, calendars: ["Academic", "Experiment"])
        let a = source("Same", sheetURL("AAA"), "BK-1", calendar: "Academic")
        let b = source("Same", sheetURL("AAA"), "BK-1", calendar: "Experiment")

        let result = try await run(engine, sources: [a, b], previewOnly: false)

        XCTAssertEqual(downloader.downloadCount(for: "AAA"), 1)
        XCTAssertEqual(result.reports.map(\.calendarName), ["Academic", "Experiment"])
        XCTAssertEqual(result.reports.map { $0.actions.map(\.status) }, [["created"], ["created"]])
        let titlesByCalendar = Dictionary(grouping: store.storedEvents.values, by: { $0.calendar?.title ?? "" })
        XCTAssertEqual(titlesByCalendar["Academic"]?.count, 1)
        XCTAssertEqual(titlesByCalendar["Experiment"]?.count, 1)
    }

    // 3. Different workbooks must not be merged, and results match one-source-at-a-time runs.
    func testDifferentWorkbooksAreNotSharedAndMatchSeparateRuns() async throws {
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(standardSheets(), in: tempDirectory), for: "AAA")
        let other = [FixtureSheet(name: "Oct 2090", days: [("B", 9)], slotLabels: [(2, "8:30-1pm")], bookings: [("B2", "BK-1")])]
        downloader.setFixture(try makeWorkbook(other, in: tempDirectory), for: "BBB")
        let (engine, _, _) = makeEngine(downloader)
        let s1 = source("A", sheetURL("AAA"), "BK-1")
        let s2 = source("B", sheetURL("BBB"), "BK-1")
        let s3 = source("A2", sheetURL("AAA"), "BK-2")

        let combined = try await run(engine, sources: [s1, s2, s3])
        XCTAssertEqual(downloader.downloadCount(for: "AAA"), 1)
        XCTAssertEqual(downloader.downloadCount(for: "BBB"), 1)

        // Baseline equivalent to the old behavior: every Source reads its own workbook.
        var separate: [[String]] = []
        for s in [s1, s2, s3] {
            let (isolatedEngine, _, _) = makeEngine(downloader)
            separate += fingerprint(try await run(isolatedEngine, sources: [s]))
        }
        XCTAssertEqual(fingerprint(combined), separate)
        XCTAssertNotEqual(combined.reports[0].actions.first?.start, combined.reports[1].actions.first?.start)
    }

    // 4. A later operation must re-read the external workbook and see changes.
    func testNextOperationRereadsExternalWorkbook() async throws {
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(standardSheets(), in: tempDirectory), for: "AAA")
        let (engine, _, _) = makeEngine(downloader)
        let s = source("One", sheetURL("AAA"), "BK-1")

        let first = try await run(engine, sources: [s])
        XCTAssertEqual(first.reports[0].totalMatchedCount, 1)

        let changed = [FixtureSheet(name: "Oct 2090", days: [("B", 5)], slotLabels: [(2, "8:30-1pm")], bookings: [])]
        downloader.setFixture(try makeWorkbook(changed, in: tempDirectory), for: "AAA")
        let second = try await run(engine, sources: [s])

        XCTAssertEqual(downloader.downloadCount(for: "AAA"), 2)
        XCTAssertEqual(second.reports[0].totalMatchedCount, 0)
    }

    // 5. A failing workbook reports an error for its Sources only and never serves earlier data.
    func testFailedWorkbookDoesNotAffectOthersOrReturnStaleData() async throws {
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(standardSheets(), in: tempDirectory), for: "AAA")
        downloader.setFixture(try makeWorkbook(standardSheets(), in: tempDirectory), for: "BBB")
        let (engine, _, _) = makeEngine(downloader)
        let a1 = source("A1", sheetURL("AAA"), "BK-1")
        let a2 = source("A2", sheetURL("AAA"), "BK-2")
        let b = source("B", sheetURL("BBB"), "BK-1")

        let good = try await run(engine, sources: [a1, a2, b])
        XCTAssertTrue(good.reports.allSatisfy { $0.errorMessage == nil })

        downloader.setFailing("AAA", true)
        let bad = try await run(engine, sources: [a1, a2, b])

        XCTAssertNotNil(bad.reports[0].errorMessage)
        XCTAssertNotNil(bad.reports[1].errorMessage)
        XCTAssertEqual(bad.reports[0].totalMatchedCount, 0)
        XCTAssertNil(bad.reports[2].errorMessage)
        XCTAssertEqual(bad.reports[2].totalMatchedCount, 1)
        // The failure is shared inside the operation (no second download attempt for the same workbook).
        XCTAssertEqual(downloader.downloadCount(for: "AAA"), 2)

        downloader.setFailing("AAA", false)
        let recovered = try await run(engine, sources: [a1])
        XCTAssertNil(recovered.reports[0].errorMessage)
        XCTAssertEqual(downloader.downloadCount(for: "AAA"), 3)
    }

    func testCorruptWorkbookFailsCleanlyAndRemovesTemporaryFile() async throws {
        let downloader = FakeWorkbookDownloader()
        let bogus = tempDirectory.appendingPathComponent("not-a-workbook.xlsx")
        try Data("not a zip".utf8).write(to: bogus)
        downloader.setFixture(bogus, for: "AAA")
        let (engine, _, _) = makeEngine(downloader)

        let result = try await run(engine, sources: [source("A", sheetURL("AAA"), "BK-1")])

        XCTAssertNotNil(result.reports[0].errorMessage)
        for file in downloader.returnedFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    // 6. Cross-day / cross-month / cross-year merge keeps the original syncKey rule.
    func testCrossMonthMergeKeepsSyncKeyRule() async throws {
        let sheets = [
            FixtureSheet(name: "Dec 2090", days: [("B", 31)],
                         slotLabels: [(2, "8:30-1pm"), (3, "1pm-6pm"), (4, "overnight")],
                         bookings: [("B4", "BK-1")]),
            FixtureSheet(name: "Jan 2091", days: [("B", 1)],
                         slotLabels: [(2, "0:00-8:30")],
                         bookings: [("B2", "BK-1")])
        ]
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(sheets, in: tempDirectory), for: "AAA")
        let (engine, _, _) = makeEngine(downloader)
        let s1 = source("Long", sheetURL("AAA"), "BK-1")
        let s2 = source("Other", sheetURL("AAA"), "BK-9")

        let result = try await run(engine, sources: [s1, s2])

        XCTAssertEqual(result.reports[0].totalMatchedCount, 1)
        let expected = digest("\(s1.stableIdentity)|Dec 2090,Jan 2091|B4,B2")
        XCTAssertEqual(result.reports[0].actions.first?.syncKey, expected)
        XCTAssertEqual(result.reports[1].totalMatchedCount, 0)
    }

    // Past bookings still take part in merging and are still counted/skipped as before.
    func testPastBookingsStillParsedAndCountedAsSkipped() async throws {
        let sheets = [
            FixtureSheet(name: "Oct 2020", days: [("B", 5)], slotLabels: [(2, "8:30-1pm")], bookings: [("B2", "BK-1")]),
            FixtureSheet(name: "Oct 2090", days: [("B", 5)], slotLabels: [(2, "8:30-1pm")], bookings: [("B2", "BK-1")])
        ]
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(sheets, in: tempDirectory), for: "AAA")
        let (engine, _, _) = makeEngine(downloader)

        let result = try await run(engine, sources: [source("One", sheetURL("AAA"), "BK-1")])

        XCTAssertEqual(result.reports[0].totalMatchedCount, 2)
        XCTAssertEqual(result.reports[0].syncedMatchedCount, 1)
        XCTAssertEqual(result.reports[0].filteredPastCount, 1)
        XCTAssertTrue(result.outputText.contains("Skipped 1 past booking."))
    }

    // 8. Cross-calendar migration still happens per Source when the workbook is shared.
    func testCrossCalendarMigrationStillWorksWithSharedWorkbook() async throws {
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(standardSheets(), in: tempDirectory), for: "AAA")
        let (engine, store, _) = makeEngine(downloader, calendars: ["Academic", "Experiment"])
        var s = source("Move", sheetURL("AAA"), "BK-1", calendar: "Academic")
        let other = source("Stay", sheetURL("AAA"), "BK-2", calendar: "Academic")

        _ = try await run(engine, sources: [s, other], previewOnly: false)
        XCTAssertEqual(store.storedEvents.count, 2)

        s.calendar = "Experiment"
        let moved = try await run(engine, sources: [s, other], previewOnly: false)

        XCTAssertEqual(moved.reports[0].actions.map(\.status), ["created"])
        XCTAssertEqual(moved.reports[1].actions.map(\.status), ["unchanged"])
        let byCalendar = Dictionary(grouping: store.storedEvents.values, by: { $0.calendar?.title ?? "" })
        XCTAssertEqual(byCalendar["Experiment"]?.count, 1)
        XCTAssertEqual(byCalendar["Academic"]?.count, 1)
        XCTAssertEqual(store.storedEvents.count, 2, "no duplicate events after migration")
    }

    // 8. Deletion protection is unchanged when a shared workbook no longer matches a Source.
    func testDeletionProtectionStillBlocksSuspiciousDeletionWithSharedWorkbook() async throws {
        let downloader = FakeWorkbookDownloader()
        downloader.setFixture(try makeWorkbook(standardSheets(), in: tempDirectory), for: "AAA")
        let (engine, store, _) = makeEngine(downloader)
        let s1 = source("One", sheetURL("AAA"), "BK-1")
        let s2 = source("Two", sheetURL("AAA"), "BK-2")
        _ = try await run(engine, sources: [s1, s2], previewOnly: false)
        XCTAssertEqual(store.storedEvents.count, 2)

        let empty = [FixtureSheet(name: "Oct 2090", days: [("B", 5)], slotLabels: [(2, "8:30-1pm")], bookings: [])]
        downloader.setFixture(try makeWorkbook(empty, in: tempDirectory), for: "AAA")

        let preview = try await run(engine, sources: [s1, s2])
        XCTAssertTrue(preview.reports.allSatisfy(\.isSuspiciousDeletion))
        XCTAssertTrue(preview.reports.allSatisfy { $0.deleteCandidates.count == 1 })

        let blocked = try await run(engine, sources: [s1, s2], previewOnly: false)
        XCTAssertTrue(blocked.reports.allSatisfy { $0.actions.contains { $0.status == "deletion rejected: suspicious" } })
        XCTAssertEqual(store.storedEvents.count, 2)

        let authorized = try await run(engine, sources: [s1, s2], previewOnly: false, authorizedDeletionSourceIDs: [s1.id])
        XCTAssertEqual(authorized.reports[0].actions.map(\.status), ["deleted"])
        XCTAssertTrue(authorized.reports[1].actions.contains { $0.status == "deletion rejected: suspicious" })
        XCTAssertEqual(store.storedEvents.count, 1)
    }

    func testWorkbookCacheKeyNormalizesGoogleLinksButSeparatesResources() {
        XCTAssertEqual(
            workbookCacheKey(for: "https://docs.google.com/spreadsheets/d/AbC-_1/edit?usp=sharing"),
            workbookCacheKey(for: "https://docs.google.com/spreadsheets/d/AbC-_1/edit#gid=42")
        )
        XCTAssertNotEqual(
            workbookCacheKey(for: "https://docs.google.com/spreadsheets/d/AbC-_1/edit"),
            workbookCacheKey(for: "https://docs.google.com/spreadsheets/d/AbC-_2/edit")
        )
        XCTAssertNil(workbookCacheKey(for: "not a source"))
    }
}
