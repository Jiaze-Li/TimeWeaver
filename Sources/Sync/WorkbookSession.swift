import Foundation

typealias WorkbookDownloader = @Sendable (String) async throws -> URL

struct WorkbookLoadTimings {
    var download: TimeInterval = 0
    var unzip: TimeInterval = 0
    var sharedStrings: TimeInterval = 0
    var worksheets: TimeInterval = 0
}

/// Immutable result of reading one workbook; safe to share between Sources.
struct LoadedWorkbook {
    let sheets: [ParsedWorkbookSheet]
    let timings: WorkbookLoadTimings
    let didDownload: Bool
}

struct WorkbookSessionSummary {
    var distinctWorkbooks = 0
    var reusedReads = 0
    var downloads = 0
    var parses = 0
    var timings = WorkbookLoadTimings()
}

/// Reads each distinct workbook at most once. Lives for a single Preview / Sync operation only;
/// nothing is kept afterwards, so the next operation always re-reads external workbooks.
actor WorkbookSession {
    private let download: WorkbookDownloader
    private var loads: [String: Task<LoadedWorkbook, Error>] = [:]
    private var summaryValue = WorkbookSessionSummary()

    init(download: @escaping WorkbookDownloader) {
        self.download = download
    }

    /// Returns the workbook and whether this call reused an earlier read in the same operation.
    func load(source: String) async throws -> (workbook: LoadedWorkbook, reused: Bool) {
        let key = workbookCacheKey(for: source) ?? "raw:\(source)"
        if let existing = loads[key] {
            summaryValue.reusedReads += 1
            return (try await existing.value, true)
        }
        let download = self.download
        let task = Task { try await Self.read(source: source, key: key, download: download) }
        loads[key] = task
        summaryValue.distinctWorkbooks += 1
        // A failure stays cached for this operation only, so sibling Sources report the same
        // error without re-downloading, and never see data from an earlier run.
        let workbook = try await task.value
        summaryValue.parses += 1
        if workbook.didDownload { summaryValue.downloads += 1 }
        summaryValue.timings.download += workbook.timings.download
        summaryValue.timings.unzip += workbook.timings.unzip
        summaryValue.timings.sharedStrings += workbook.timings.sharedStrings
        summaryValue.timings.worksheets += workbook.timings.worksheets
        return (workbook, false)
    }

    func summary() -> WorkbookSessionSummary {
        summaryValue
    }

    private static func read(
        source: String,
        key: String,
        download: WorkbookDownloader
    ) async throws -> LoadedWorkbook {
        var timings = WorkbookLoadTimings()
        let now = { ProcessInfo.processInfo.systemUptime }

        let downloadStart = now()
        let workbookURL = try await download(source)
        timings.download = now() - downloadStart

        let isTemporary = !key.hasPrefix("file:")
        defer {
            if isTemporary {
                try? FileManager.default.removeItem(at: workbookURL)
            }
        }

        let unzipStart = now()
        let package = try XLSXPackage(xlsxURL: workbookURL)
        timings.unzip = now() - unzipStart
        defer { package.cleanup() }

        let workbookData = try package.data(at: "xl/workbook.xml")
        let relsData = try package.data(at: "xl/_rels/workbook.xml.rels")
        let sharedStringsData = (try? package.data(at: "xl/sharedStrings.xml")) ?? Data()

        let workbookSheets = WorkbookParser().parse(data: workbookData)
        let relationships = RelationshipParser().parse(data: relsData)

        let sharedStart = now()
        let sharedStrings = SharedStringsParser().parse(data: sharedStringsData)
        timings.sharedStrings = now() - sharedStart

        let worksheetStart = now()
        var parsedSheets: [ParsedWorkbookSheet] = []
        for sheet in workbookSheets {
            guard let target = relationships[sheet.relationshipID] else { continue }
            let sheetData = try package.data(at: normalizeWorkbookPath(target))
            let worksheet = WorksheetParser(sharedStrings: sharedStrings).parse(data: sheetData)
            if worksheet.maxRow == 0 { continue }
            let parsedMonth = parseMonthSheet(sheet.name)
            parsedSheets.append(
                ParsedWorkbookSheet(
                    name: sheet.name,
                    year: parsedMonth?.0,
                    month: parsedMonth?.1,
                    worksheet: worksheet
                )
            )
        }
        timings.worksheets = now() - worksheetStart

        return LoadedWorkbook(sheets: parsedSheets, timings: timings, didDownload: isTemporary)
    }
}
