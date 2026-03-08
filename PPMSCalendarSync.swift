import SwiftUI
import Foundation
import EventKit

private let appSupportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PPMSCalendarSync", isDirectory: true)
private let settingsURL = appSupportDirectory.appendingPathComponent("settings.json")
private let stateURL = appSupportDirectory.appendingPathComponent("sync-state.json")

struct SourceItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String
    var source: String
    var bookingID: String
    var calendar: String
}

struct SlotRule: Codable, Equatable {
    var sheetLabel: String
    var start: String
    var end: String
    var endsNextDay: Bool
}

struct AppSettings: Codable {
    var sources: [SourceItem]
    var slotRules: [SlotRule]
    var autoSyncEnabled: Bool
    var autoSyncMinutes: Int
    var upcomingOnly: Bool

    enum CodingKeys: String, CodingKey {
        case sources
        case slotRules
        case autoSyncEnabled
        case autoSyncMinutes
        case upcomingOnly
    }

    init(sources: [SourceItem], slotRules: [SlotRule], autoSyncEnabled: Bool, autoSyncMinutes: Int, upcomingOnly: Bool) {
        self.sources = sources
        self.slotRules = slotRules
        self.autoSyncEnabled = autoSyncEnabled
        self.autoSyncMinutes = autoSyncMinutes
        self.upcomingOnly = upcomingOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decodeIfPresent([SourceItem].self, forKey: .sources) ?? defaultSources()
        self.slotRules = try container.decodeIfPresent([SlotRule].self, forKey: .slotRules) ?? defaultSlotRules()
        self.autoSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled) ?? false
        self.autoSyncMinutes = try container.decodeIfPresent(Int.self, forKey: .autoSyncMinutes) ?? 15
        self.upcomingOnly = try container.decodeIfPresent(Bool.self, forKey: .upcomingOnly) ?? true
    }
}

struct StoredEvent: Codable {
    var eventIdentifier: String
    var sourceID: String
    var calendar: String
    var title: String
    var startISO: String
    var endISO: String
}

struct SyncState: Codable {
    var events: [String: StoredEvent]
}

struct WorkbookSheet {
    var name: String
    var relationshipID: String
    var state: String
}

struct SlotOccurrence {
    var start: Date
    var end: Date
    var sheetName: String
    var cellReference: String
    var slotLabel: String
}

struct ReservationEvent: Identifiable {
    var id: String { syncKey }
    var syncKey: String
    var sourceID: String
    var sourceName: String
    var sourceLink: String
    var bookingID: String
    var calendarName: String
    var start: Date
    var end: Date
    var sheetNames: [String]
    var cellReferences: [String]
}

struct EventAction {
    var status: String
    var title: String
    var start: Date
    var end: Date
}

struct DeleteCandidate {
    var title: String
    var startISO: String
    var endISO: String
}

struct SourceSyncReport: Identifiable {
    var id = UUID()
    var sourceName: String
    var bookingID: String
    var calendarName: String
    var totalMatchedCount: Int
    var syncedMatchedCount: Int
    var filteredPastCount: Int
    var actions: [EventAction]
    var deleteCandidates: [DeleteCandidate]
    var errorMessage: String?
}

struct SyncRunResult {
    var reports: [SourceSyncReport]
    var outputText: String
}

struct ExtractionResult {
    var allEvents: [ReservationEvent]
    var filteredEvents: [ReservationEvent]
    var filteredPastCount: Int
}

enum AppFailure: LocalizedError {
    case invalidSource
    case unsupportedSource(String)
    case missingWorkbookData(String)
    case invalidTime(String)
    case calendarAccessDenied
    case calendarNotFound(String)
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "The sheet link or workbook path is invalid."
        case .unsupportedSource(let value):
            return "Unsupported source: \(value)"
        case .missingWorkbookData(let value):
            return "Workbook data is missing: \(value)"
        case .invalidTime(let value):
            return "Invalid time setting: \(value)"
        case .calendarAccessDenied:
            return "Calendar access was denied."
        case .calendarNotFound(let name):
            return "Calendar not found: \(name)"
        case .syncFailed(let message):
            return message
        }
    }
}

private let monthAliases: [String: Int] = [
    "january": 1, "jan": 1,
    "february": 2, "feb": 2,
    "march": 3, "mar": 3,
    "april": 4, "apri": 4, "apr": 4,
    "may": 5,
    "june": 6, "jun": 6,
    "july": 7, "jul": 7,
    "august": 8, "aug": 8, "ang": 8,
    "september": 9, "sept": 9, "sep": 9,
    "october": 10, "oct": 10,
    "november": 11, "nov": 11,
    "december": 12, "dec": 12
]

private func defaultSlotRules() -> [SlotRule] {
    [
        SlotRule(sheetLabel: "8:30-1pm", start: "08:30", end: "13:00", endsNextDay: false),
        SlotRule(sheetLabel: "1pm-6pm", start: "13:00", end: "18:00", endsNextDay: false),
        SlotRule(sheetLabel: "overnight", start: "18:00", end: "08:30", endsNextDay: true),
    ]
}

private func defaultSources() -> [SourceItem] {
    [
        SourceItem(
            name: "ppms",
            source: "https://docs.google.com/spreadsheets/d/1J7XCLh20n1qBkhBNyfF0XwnM2vItuOlGl6j5iQR1aVg/edit?usp=sharing",
            bookingID: "LJZ",
            calendar: "Experiment"
        )
    ]
}

private final class SettingsStore {
    static func loadSettings() -> AppSettings {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings(
                sources: defaultSources(),
                slotRules: defaultSlotRules(),
                autoSyncEnabled: false,
                autoSyncMinutes: 15,
                upcomingOnly: true
            )
        }
        return settings
    }

    static func saveSettings(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL)
        } catch {
        }
    }

    static func loadState() -> SyncState {
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else {
            return SyncState(events: [:])
        }
        return state
    }

    static func saveState(_ state: SyncState) {
        do {
            try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL)
        } catch {
        }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var currentText = ""
    private var insideSI = false
    private var insideTextNode = false

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "si" {
            insideSI = true
            currentText = ""
        } else if elementName == "t", insideSI {
            insideTextNode = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideSI, insideTextNode {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            insideTextNode = false
        } else if elementName == "si" {
            strings.append(currentText)
            insideSI = false
            currentText = ""
        }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    private(set) var sheets: [WorkbookSheet] = []

    func parse(data: Data) -> [WorkbookSheet] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return sheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName == "sheet" else { return }
        if let name = attributeDict["name"], let rid = attributeDict["r:id"] {
            sheets.append(
                WorkbookSheet(
                    name: name,
                    relationshipID: rid,
                    state: attributeDict["state"] ?? "visible"
                )
            )
        }
    }
}

private final class RelationshipParser: NSObject, XMLParserDelegate {
    private(set) var mapping: [String: String] = [:]

    func parse(data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return mapping
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName == "Relationship" else { return }
        guard let type = attributeDict["Type"], type.contains("/worksheet"),
              let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        mapping[id] = target
    }
}

private final class WorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var cellsByRow: [Int: [Int: String]] = [:]
    private(set) var maxRow = 0
    private(set) var maxColumn = 0

    private var currentReference = ""
    private var currentType = ""
    private var currentValue = ""
    private var captureValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parse(data: Data) -> WorksheetParser {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return self
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "c" {
            currentReference = attributeDict["r"] ?? ""
            currentType = attributeDict["t"] ?? ""
            currentValue = ""
        } else if elementName == "v" || elementName == "t" {
            captureValue = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureValue {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "v" || elementName == "t" {
            captureValue = false
        } else if elementName == "c" {
            guard let (row, column) = decodeCellReference(currentReference) else { return }
            var resolved = currentValue
            if currentType == "s", let index = Int(currentValue), sharedStrings.indices.contains(index) {
                resolved = sharedStrings[index]
            }
            if !resolved.isEmpty {
                var rowCells = cellsByRow[row] ?? [:]
                rowCells[column] = resolved
                cellsByRow[row] = rowCells
                maxRow = max(maxRow, row)
                maxColumn = max(maxColumn, column)
            }
        }
    }
}

private struct XLSXPackage {
    let rootURL: URL

    init(xlsxURL: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppms-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", xlsxURL.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw AppFailure.syncFailed("Could not unpack workbook.")
        }
        rootURL = tempDir
    }

    func data(at relativePath: String) throws -> Data {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw AppFailure.missingWorkbookData(relativePath)
        }
        return data
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct ReservationExtractor {
    static func extract(source: SourceItem, slotRules: [SlotRule], upcomingOnly: Bool) async throws -> ExtractionResult {
        let workbookURL = try await downloadWorkbook(from: source.source)
        let isTemporary = !FileManager.default.fileExists(atPath: source.source)
        let package = try XLSXPackage(xlsxURL: workbookURL)
        defer {
            package.cleanup()
            if isTemporary {
                try? FileManager.default.removeItem(at: workbookURL)
            }
        }

        let workbookData = try package.data(at: "xl/workbook.xml")
        let relsData = try package.data(at: "xl/_rels/workbook.xml.rels")
        let sharedStringsData = (try? package.data(at: "xl/sharedStrings.xml")) ?? Data()

        let workbookSheets = WorkbookParser().parse(data: workbookData)
        let relationships = RelationshipParser().parse(data: relsData)
        let sharedStrings = SharedStringsParser().parse(data: sharedStringsData)

        let timeZone = TimeZone(identifier: "Asia/Singapore") ?? .current
        let calendar = Calendar(identifier: .gregorian)
        var slotRuleMap: [String: SlotRule] = [:]
        for rule in slotRules {
            slotRuleMap[rule.sheetLabel] = rule
        }

        var occurrences: [SlotOccurrence] = []
        for sheet in workbookSheets {
            guard let (year, month) = parseMonthSheet(sheet.name) else { continue }
            guard let target = relationships[sheet.relationshipID] else { continue }
            let sheetData = try package.data(at: normalizeWorkbookPath(target))
            let worksheet = WorksheetParser(sharedStrings: sharedStrings).parse(data: sheetData)
            if worksheet.maxRow == 0 { continue }

            for row in 1...worksheet.maxRow {
                var dayColumns: [Int: Int] = [:]
                for column in 1...worksheet.maxColumn {
                    if let text = worksheet.cellsByRow[row]?[column], let day = dayNumber(from: text) {
                        dayColumns[column] = day
                    }
                }
                if dayColumns.isEmpty { continue }

                var slotRows: [(SlotRule, Int)] = []
                for offset in 1...3 {
                    let label = worksheet.cellsByRow[row + offset]?[1] ?? ""
                    if let rule = slotRuleMap[label] {
                        slotRows.append((rule, row + offset))
                    }
                }
                if slotRows.isEmpty { continue }

                for (column, day) in dayColumns {
                    var components = DateComponents()
                    components.year = year
                    components.month = month
                    components.day = day
                    components.timeZone = timeZone
                    guard let baseDate = calendar.date(from: components) else { continue }

                    for (rule, slotRow) in slotRows {
                        guard let value = worksheet.cellsByRow[slotRow]?[column],
                              value.caseInsensitiveCompare(source.bookingID) == .orderedSame else { continue }
                        let start = try buildDate(from: baseDate, timeString: rule.start, in: timeZone)
                        var end = try buildDate(from: baseDate, timeString: rule.end, in: timeZone)
                        if rule.endsNextDay {
                            end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
                        }
                        let reference = "\(columnLetters(column))\(slotRow)"
                        occurrences.append(
                            SlotOccurrence(
                                start: start,
                                end: end,
                                sheetName: sheet.name,
                                cellReference: reference,
                                slotLabel: rule.sheetLabel
                            )
                        )
                    }
                }
            }
        }

        occurrences.sort { $0.start < $1.start }
        let allEvents = mergeOccurrences(occurrences: occurrences, source: source)
        let filteredEvents: [ReservationEvent]
        if upcomingOnly {
            let now = Date()
            filteredEvents = allEvents.filter { $0.end >= now }
        } else {
            filteredEvents = allEvents
        }
        return ExtractionResult(
            allEvents: allEvents,
            filteredEvents: filteredEvents,
            filteredPastCount: max(allEvents.count - filteredEvents.count, 0)
        )
    }

    private static func mergeOccurrences(occurrences: [SlotOccurrence], source: SourceItem) -> [ReservationEvent] {
        let sourceID = digest("\(source.name)|\(source.source)|\(source.bookingID)|\(source.calendar)")
        var merged: [ReservationEvent] = []

        for occurrence in occurrences {
            if var current = merged.last, occurrence.start <= current.end {
                current.end = max(current.end, occurrence.end)
                current.sheetNames.append(occurrence.sheetName)
                current.cellReferences.append(occurrence.cellReference)
                current.syncKey = digest("\(sourceID)|\(current.sheetNames.joined(separator: ","))|\(current.cellReferences.joined(separator: ","))|\(source.bookingID)")
                merged[merged.count - 1] = current
            } else {
                let syncKey = digest("\(sourceID)|\(occurrence.sheetName)|\(occurrence.cellReference)|\(source.bookingID)")
                merged.append(
                    ReservationEvent(
                        syncKey: syncKey,
                        sourceID: sourceID,
                        sourceName: source.name,
                        sourceLink: source.source,
                        bookingID: source.bookingID,
                        calendarName: source.calendar,
                        start: occurrence.start,
                        end: occurrence.end,
                        sheetNames: [occurrence.sheetName],
                        cellReferences: [occurrence.cellReference]
                    )
                )
            }
        }
        return merged
    }
}

private actor CalendarSyncEngine {
    private let store = EKEventStore()

    func calendarNames() async throws -> [String] {
        try await ensureAccess()
        return store.calendars(for: .event)
            .map(\.title)
            .sorted()
    }

    func sync(sources: [SourceItem], slotRules: [SlotRule], upcomingOnly: Bool, previewOnly: Bool) async throws -> SyncRunResult {
        try await ensureAccess()
        var state = SettingsStore.loadState()
        var reports: [SourceSyncReport] = []
        var lines: [String] = []

        for source in sources where source.enabled {
            do {
                let extraction = try await ReservationExtractor.extract(
                    source: source,
                    slotRules: slotRules,
                    upcomingOnly: upcomingOnly
                )
                let report = try syncSource(
                    source: source,
                    extraction: extraction,
                    state: &state,
                    previewOnly: previewOnly
                )
                reports.append(report)

                lines.append("Source: \(report.sourceName)")
                lines.append("Calendar: \(report.calendarName)")
                lines.append("Booking ID: \(report.bookingID)")
                lines.append("Matched reservations: \(report.totalMatchedCount)")
                if upcomingOnly {
                    lines.append("Upcoming reservations used for sync: \(report.syncedMatchedCount)")
                    if report.filteredPastCount > 0 {
                        lines.append("Filtered out past reservations: \(report.filteredPastCount)")
                    }
                }
                if report.actions.isEmpty && report.deleteCandidates.isEmpty {
                    lines.append(previewOnly ? "No calendar changes would be made." : "No calendar changes were needed.")
                }
                for action in report.actions {
                    lines.append("\(action.status.uppercased())  \(iso8601(action.start)) -> \(iso8601(action.end))  \(action.title)")
                }
                if !report.deleteCandidates.isEmpty {
                    lines.append("Manual delete candidates:")
                    for candidate in report.deleteCandidates {
                        lines.append("MANUAL  \(candidate.startISO) -> \(candidate.endISO)  \(candidate.title)")
                    }
                }
                lines.append("")
            } catch {
                let message = error.localizedDescription
                let report = SourceSyncReport(
                    sourceName: source.name,
                    bookingID: source.bookingID,
                    calendarName: source.calendar,
                    totalMatchedCount: 0,
                    syncedMatchedCount: 0,
                    filteredPastCount: 0,
                    actions: [],
                    deleteCandidates: [],
                    errorMessage: message
                )
                reports.append(report)
                lines.append("Source: \(source.name)")
                lines.append("Calendar: \(source.calendar)")
                lines.append("Booking ID: \(source.bookingID)")
                lines.append("ERROR: \(message)")
                lines.append("")
            }
        }

        if !previewOnly {
            SettingsStore.saveState(state)
        }
        return SyncRunResult(reports: reports, outputText: lines.joined(separator: "\n"))
    }

    private func syncSource(source: SourceItem, extraction: ExtractionResult, state: inout SyncState, previewOnly: Bool) throws -> SourceSyncReport {
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == source.calendar }) else {
            throw AppFailure.calendarNotFound(source.calendar)
        }

        var actions: [EventAction] = []
        let events = extraction.filteredEvents
        let activeKeys = Set(events.map(\.syncKey))

        for event in events {
            let customURL = URL(string: "ppms-sync://event/\(event.syncKey)")!
            let existingRecord = state.events[event.syncKey]
            let existingEvent = findExistingEvent(for: event, stateRecord: existingRecord, calendar: calendar, customURL: customURL)
            let target = existingEvent ?? EKEvent(eventStore: store)
            let oldSignature = eventSignature(target)

            target.calendar = calendar
            target.title = event.sourceName
            target.startDate = event.start
            target.endDate = event.end
            target.notes = event.sourceLink
            target.url = customURL

            let newSignature = eventSignature(target)
            let status: String
            if existingEvent == nil {
                status = previewOnly ? "would create" : "created"
                if !previewOnly {
                    try store.save(target, span: .thisEvent, commit: true)
                }
            } else if oldSignature != newSignature {
                status = previewOnly ? "would update" : "updated"
                if !previewOnly {
                    try store.save(target, span: .thisEvent, commit: true)
                }
            } else {
                status = "unchanged"
            }

            actions.append(EventAction(status: status, title: event.sourceName, start: event.start, end: event.end))
            if !previewOnly, let identifier = target.eventIdentifier {
                state.events[event.syncKey] = StoredEvent(
                    eventIdentifier: identifier,
                    sourceID: event.sourceID,
                    calendar: event.calendarName,
                    title: event.sourceName,
                    startISO: iso8601(event.start),
                    endISO: iso8601(event.end)
                )
            }
        }

        let deleteCandidates = state.events.compactMap { key, value -> DeleteCandidate? in
            guard value.sourceID == digest("\(source.name)|\(source.source)|\(source.bookingID)|\(source.calendar)") else {
                return nil
            }
            guard !activeKeys.contains(key) else { return nil }
            return DeleteCandidate(title: value.title, startISO: value.startISO, endISO: value.endISO)
        }.sorted { $0.startISO < $1.startISO }

        return SourceSyncReport(
            sourceName: source.name,
            bookingID: source.bookingID,
            calendarName: source.calendar,
            totalMatchedCount: extraction.allEvents.count,
            syncedMatchedCount: events.count,
            filteredPastCount: extraction.filteredPastCount,
            actions: actions,
            deleteCandidates: deleteCandidates,
            errorMessage: nil
        )
    }

    private func findExistingEvent(for event: ReservationEvent, stateRecord: StoredEvent?, calendar: EKCalendar, customURL: URL) -> EKEvent? {
        if let stateRecord,
           let item = store.calendarItem(withIdentifier: stateRecord.eventIdentifier) as? EKEvent {
            return item
        }

        let start = Calendar.current.date(byAdding: .day, value: -2, to: event.start) ?? event.start
        let end = Calendar.current.date(byAdding: .day, value: 2, to: event.end) ?? event.end
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).first(where: { $0.url == customURL })
    }

    private func ensureAccess() async throws {
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToEvents()
            if !granted { throw AppFailure.calendarAccessDenied }
        } else {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            if !granted { throw AppFailure.calendarAccessDenied }
        }
    }
}

private func eventSignature(_ event: EKEvent) -> String {
    "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)|\(event.notes ?? "")|\(event.url?.absoluteString ?? "")|\(event.calendar.title)"
}

private func digest(_ text: String) -> String {
    let data = Data(text.utf8)
    let digest = data.withUnsafeBytes { buffer in
        Array(buffer)
    }.reduce(into: UInt64(1469598103934665603)) { hash, byte in
        hash = (hash ^ UInt64(byte)) &* 1099511628211
    }
    return String(format: "%016llx", digest)
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    return formatter.string(from: date)
}

private func parseMonthSheet(_ title: String) -> (Int, Int)? {
    let yearRegex = try! NSRegularExpression(pattern: "(20\\d{2})")
    guard let match = yearRegex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
          let range = Range(match.range(at: 1), in: title),
          let year = Int(title[range]) else { return nil }
    let compact = title.lowercased().replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
    for alias in monthAliases.keys.sorted(by: { $0.count > $1.count }) {
        if compact.hasPrefix(alias), let month = monthAliases[alias] {
            return (year, month)
        }
    }
    return nil
}

private func dayNumber(from text: String) -> Int? {
    if let value = Int(text) {
        return (1...31).contains(value) ? value : nil
    }
    if let value = Double(text), value.rounded() == value {
        let intValue = Int(value)
        return (1...31).contains(intValue) ? intValue : nil
    }
    return nil
}

private func decodeCellReference(_ reference: String) -> (Int, Int)? {
    let letters = reference.prefix { $0.isLetter }
    let numbers = String(reference.reversed().prefix { $0.isNumber }.reversed())
    guard !letters.isEmpty, let row = Int(numbers) else { return nil }
    var column = 0
    for scalar in letters.uppercased().unicodeScalars {
        column = column * 26 + Int(scalar.value) - 64
    }
    return (row, column)
}

private func columnLetters(_ value: Int) -> String {
    var value = value
    var output = ""
    while value > 0 {
        let remainder = (value - 1) % 26
        output = String(UnicodeScalar(65 + remainder)!) + output
        value = (value - 1) / 26
    }
    return output
}

private func buildDate(from baseDate: Date, timeString: String, in timeZone: TimeZone) throws -> Date {
    let parts = timeString.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
        throw AppFailure.invalidTime(timeString)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: baseDate)
    var full = DateComponents()
    full.year = components.year
    full.month = components.month
    full.day = components.day
    full.hour = hour
    full.minute = minute
    full.timeZone = timeZone
    guard let date = calendar.date(from: full) else {
        throw AppFailure.invalidTime(timeString)
    }
    return date
}

private func normalizeWorkbookPath(_ target: String) -> String {
    if target.hasPrefix("xl/") {
        return target
    }
    if target.hasPrefix("/xl/") {
        return String(target.dropFirst())
    }
    return "xl/\(target)"
}

private func downloadWorkbook(from source: String) async throws -> URL {
    let expanded = NSString(string: source).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded) {
        return URL(fileURLWithPath: expanded)
    }

    let downloadURL: URL
    if source.contains("docs.google.com/spreadsheets") {
        let pattern = "/d/([a-zA-Z0-9-_]+)"
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else {
            throw AppFailure.invalidSource
        }
        let sheetID = String(source[range])
        guard let url = URL(string: "https://docs.google.com/spreadsheets/d/\(sheetID)/export?format=xlsx") else {
            throw AppFailure.invalidSource
        }
        downloadURL = url
    } else if let url = URL(string: source), let scheme = url.scheme, scheme.hasPrefix("http") {
        downloadURL = url
    } else {
        throw AppFailure.unsupportedSource(source)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpAdditionalHeaders = [
        "User-Agent": "PPMSCalendarSync/1.0"
    ]
    let session = URLSession(configuration: configuration)
    let request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    let (tempURL, response) = try await session.download(for: request)
    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
        throw AppFailure.syncFailed("Workbook download failed with HTTP \(httpResponse.statusCode).")
    }
    let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("ppms-\(UUID().uuidString).xlsx")
    try? FileManager.default.removeItem(at: finalURL)
    try FileManager.default.moveItem(at: tempURL, to: finalURL)
    return finalURL
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [SourceItem]
    @Published var slotRules: [SlotRule]
    @Published var selectedSourceID: UUID?
    @Published var draftEnabled = true
    @Published var draftName = ""
    @Published var draftSource = ""
    @Published var draftBookingID = ""
    @Published var draftCalendar = "Experiment"
    @Published var calendars: [String] = ["Experiment"]
    @Published var output = ""
    @Published var status = "Ready"
    @Published var isBusy = false
    @Published var autoSyncEnabled: Bool
    @Published var autoSyncMinutes: String
    @Published var upcomingOnly: Bool

    private let engine = CalendarSyncEngine()
    private var timer: Timer?

    init() {
        let settings = SettingsStore.loadSettings()
        self.sources = settings.sources
        self.slotRules = settings.slotRules
        self.autoSyncEnabled = settings.autoSyncEnabled
        self.autoSyncMinutes = String(settings.autoSyncMinutes)
        self.upcomingOnly = settings.upcomingOnly
        if let first = settings.sources.first {
            self.selectedSourceID = first.id
            self.draftEnabled = first.enabled
            self.draftName = first.name
            self.draftSource = first.source
            self.draftBookingID = first.bookingID
            self.draftCalendar = first.calendar
        } else {
            let first = defaultSources()[0]
            self.sources = [first]
            self.selectedSourceID = first.id
            self.draftEnabled = first.enabled
            self.draftName = first.name
            self.draftSource = first.source
            self.draftBookingID = first.bookingID
            self.draftCalendar = first.calendar
        }
        refreshCalendars()
        rescheduleTimer()
    }

    func refreshCalendars() {
        if isBusy { return }
        isBusy = true
        status = "Loading calendars..."
        Task {
            do {
                let values = try await engine.calendarNames()
                calendars = values.isEmpty ? ["Experiment"] : values
                if !calendars.contains(draftCalendar) {
                    draftCalendar = calendars.first ?? "Experiment"
                }
                status = "Calendars loaded"
            } catch {
                status = error.localizedDescription
                output = error.localizedDescription
            }
            isBusy = false
        }
    }

    func selectSource(_ item: SourceItem?) {
        guard let item else { return }
        selectedSourceID = item.id
        draftEnabled = item.enabled
        draftName = item.name
        draftSource = item.source
        draftBookingID = item.bookingID
        draftCalendar = item.calendar
    }

    func newSource() {
        selectedSourceID = nil
        draftEnabled = true
        draftName = "ppms"
        draftSource = ""
        draftBookingID = ""
        draftCalendar = calendars.first ?? "Experiment"
    }

    func saveCurrentSource() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = draftSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let booking = draftBookingID.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = draftCalendar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !source.isEmpty, !booking.isEmpty, !calendar.isEmpty else {
            status = "Fill in all source fields before saving"
            return
        }

        let item = SourceItem(
            id: selectedSourceID ?? UUID(),
            enabled: draftEnabled,
            name: name,
            source: source,
            bookingID: booking,
            calendar: calendar
        )

        if let selectedSourceID, let index = sources.firstIndex(where: { $0.id == selectedSourceID }) {
            sources[index] = item
        } else {
            sources.append(item)
        }

        selectedSourceID = item.id
        persistSettings()
        status = "Source saved"
    }

    func removeSelectedSource() {
        guard let selectedSourceID, let index = sources.firstIndex(where: { $0.id == selectedSourceID }) else { return }
        sources.remove(at: index)
        if let next = sources.first {
            selectSource(next)
        } else {
            newSource()
        }
        persistSettings()
        status = "Source removed"
    }

    func persistRules() {
        persistSettings()
    }

    func addSlotRule() {
        slotRules.append(
            SlotRule(
                sheetLabel: "new-slot",
                start: "09:00",
                end: "10:00",
                endsNextDay: false
            )
        )
        persistSettings()
    }

    func removeSlotRules(at offsets: IndexSet) {
        slotRules.remove(atOffsets: offsets)
        persistSettings()
    }

    func previewAll() {
        runSync(previewOnly: true)
    }

    func syncAll() {
        runSync(previewOnly: false)
    }

    func automationChanged() {
        persistSettings()
        rescheduleTimer()
    }

    func openCalendarApp() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    private func runSync(previewOnly: Bool) {
        if isBusy { return }
        let enabledSources = sources.filter(\.enabled)
        guard !enabledSources.isEmpty else {
            status = "Enable at least one source first"
            return
        }

        isBusy = true
        output = ""
        status = previewOnly ? "Previewing..." : "Syncing..."

        Task {
            do {
                let result = try await engine.sync(
                    sources: enabledSources,
                    slotRules: slotRules,
                    upcomingOnly: upcomingOnly,
                    previewOnly: previewOnly
                )
                output = result.outputText
                status = previewOnly ? "Preview complete" : "Sync complete"
            } catch {
                output = error.localizedDescription
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func persistSettings() {
        let minutes = max(Int(autoSyncMinutes) ?? 15, 1)
        SettingsStore.saveSettings(
            AppSettings(
                sources: sources,
                slotRules: slotRules,
                autoSyncEnabled: autoSyncEnabled,
                autoSyncMinutes: minutes,
                upcomingOnly: upcomingOnly
            )
        )
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoSyncEnabled else { return }
        let minutes = max(Int(autoSyncMinutes) ?? 15, 1)
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runSync(previewOnly: false)
            }
        }
    }
}

struct SlotRuleEditor: View {
    @Binding var rule: SlotRule

    var body: some View {
        ViewThatFits(in: .vertical) {
            HStack(alignment: .center, spacing: 10) {
                TextField("Sheet label", text: $rule.sheetLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, maxWidth: 220)
                TextField("08:30", text: $rule.start)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("to")
                    .foregroundStyle(.secondary)
                TextField("13:00", text: $rule.end)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Toggle("Next day", isOn: $rule.endsNextDay)
                    .toggleStyle(.checkbox)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Sheet label", text: $rule.sheetLabel)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    TextField("08:30", text: $rule.start)
                        .textFieldStyle(.roundedBorder)
                    Text("to")
                        .foregroundStyle(.secondary)
                    TextField("13:00", text: $rule.end)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Next day", isOn: $rule.endsNextDay)
                    .toggleStyle(.checkbox)
            }
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        GeometryReader { proxy in
            let useSidebarLayout = proxy.size.width >= 980

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerPane

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        SummaryCard(title: "Sources", value: "\(model.sources.count)", symbol: "square.stack.3d.up")
                        SummaryCard(title: "Enabled", value: "\(model.sources.filter(\.enabled).count)", symbol: "checkmark.circle")
                        SummaryCard(title: "Calendars", value: "\(model.calendars.count)", symbol: "calendar")
                    }

                    if useSidebarLayout {
                        HStack(alignment: .top, spacing: 16) {
                            sourcesPane
                                .frame(width: 240)
                            editorPane
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        sourcesPane
                        editorPane
                    }

                    outputPane
                    statusPane
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 420, minHeight: 760)
    }

    private var headerPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PPMS Calendar Sync")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Sync booking IDs from Google Sheets into Apple Calendar without duplicating events.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Calendar") {
                model.openCalendarApp()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.headline)
            TextEditor(text: $model.output)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
    }

    private var statusPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.status)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.headline)
            List(selection: $model.selectedSourceID) {
                ForEach(model.sources) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: item.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.enabled ? .green : .secondary)
                            Text(item.name)
                                .lineLimit(1)
                        }
                        Text("\(item.bookingID) -> \(item.calendar)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(item.id)
                }
            }
            .frame(minHeight: 220)
            .onChange(of: model.selectedSourceID) { value in
                if let value, let item = model.sources.first(where: { $0.id == value }) {
                    model.selectSource(item)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("New") { model.newSource() }
                Button("Save Source") { model.saveCurrentSource() }
                Button("Remove") { model.removeSelectedSource() }
            }
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Source Details") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enabled", isOn: $model.draftEnabled)
                        .toggleStyle(.checkbox)

                    Text("Sheet Link")
                    TextField("Google Sheets link or local .xlsx path", text: $model.draftSource)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 10) {
                        bookingFields
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Calendar")
                            Picker("", selection: $model.draftCalendar) {
                                ForEach(model.calendars, id: \.self) { calendar in
                                    Text(calendar).tag(calendar)
                                }
                            }
                            .labelsHidden()
                        }
                        Button("Refresh Calendars") {
                            model.refreshCalendars()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Slot Times") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.slotRules.enumerated()), id: \.offset) { index, _ in
                        SlotRuleEditor(rule: $model.slotRules[index])
                            .onChange(of: model.slotRules[index]) { _ in
                                model.persistRules()
                            }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Add Slot Rule") {
                            model.addSlotRule()
                        }
                        if !model.slotRules.isEmpty {
                            Button("Remove Last Rule") {
                                model.removeSlotRules(at: IndexSet(integer: model.slotRules.count - 1))
                            }
                        }
                    }
                    Text("Use 24-hour format, for example 08:30 or 18:00.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Automation") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Only upcoming reservations", isOn: $model.upcomingOnly)
                        .onChange(of: model.upcomingOnly) { _ in
                            model.automationChanged()
                        }
                    Toggle("Auto sync while the app is open", isOn: $model.autoSyncEnabled)
                        .onChange(of: model.autoSyncEnabled) { _ in
                            model.automationChanged()
                        }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Interval (minutes)")
                        TextField("15", text: $model.autoSyncMinutes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onSubmit {
                                model.automationChanged()
                            }
                            .onChange(of: model.autoSyncMinutes) { _ in
                                model.automationChanged()
                            }
                    }
                    Text("The app polls saved sources and only adds or updates matching bookings. Removed bookings are shown as manual delete candidates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("Preview") {
                    model.previewAll()
                }
                .disabled(model.isBusy)
                Button("Sync Enabled Sources") {
                    model.syncAll()
                }
                .disabled(model.isBusy)
            }
        }
    }

    private var bookingFields: some View {
        Group {
            VStack(alignment: .leading) {
                Text("Booking ID")
                TextField("LJZ", text: $model.draftBookingID)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading) {
                Text("Event Title")
                TextField("ppms", text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

#if PPMS_TEST_RUNNER
@main
struct PPMSCalendarSyncTestRunner {
    static func main() async {
        let source = SourceItem(
            name: "ppms",
            source: "https://docs.google.com/spreadsheets/d/1J7XCLh20n1qBkhBNyfF0XwnM2vItuOlGl6j5iQR1aVg/edit?usp=sharing",
            bookingID: "LJZ",
            calendar: "Experiment"
        )
        do {
            let result = try await ReservationExtractor.extract(source: source, slotRules: defaultSlotRules(), upcomingOnly: false)
            print("All matched reservations: \(result.allEvents.count)")
            for event in result.allEvents {
                print("\(iso8601(event.start))\t\(iso8601(event.end))\t\(event.sourceName)")
            }
            let preview = try await CalendarSyncEngine().sync(
                sources: [source],
                slotRules: defaultSlotRules(),
                upcomingOnly: true,
                previewOnly: true
            )
            print("")
            print("Preview output:")
            print(preview.outputText)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}
#else
@main
struct PPMSCalendarSyncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
#endif
