import Foundation
#if canImport(TimeWeaverCore)
import TimeWeaverCore
#endif

private let primaryEventURLScheme = "timeweaver-sync"
private let legacyEventURLScheme = "ppms-sync"

func primaryEventURL(for syncKey: String) -> URL? {
    URL(string: "\(primaryEventURLScheme)://event/\(syncKey)")
}

func eventURLs(for syncKey: String) -> [URL] {
    [primaryEventURLScheme, legacyEventURLScheme].compactMap {
        URL(string: "\($0)://event/\(syncKey)")
    }
}

struct ReservationExtractor {
    let aiNormalizer: AIWorkbookNormalizerProtocol
    let localImageParser: LocalImageParserProtocol

    func extract(
        source: SourceItem,
        workdayHours: WorkdayHours,
        upcomingOnly: Bool,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        timeZone: TimeZone,
        referenceDate: Date = Date()
    ) async throws -> ExtractionResult {
        if let imageURL = localImageURL(from: source.source) {
            return try await extractImageSource(
                source: source,
                workdayHours: workdayHours,
                upcomingOnly: upcomingOnly,
                parserMode: parserMode,
                aiConfiguration: aiConfiguration,
                imageURL: imageURL,
                timeZone: timeZone,
                referenceDate: referenceDate
            )
        }

        let downloadStart = ProcessInfo.processInfo.systemUptime
        let workbookURL = try await downloadWorkbook(from: source.source)
        let downloadSeconds = ProcessInfo.processInfo.systemUptime - downloadStart

        let isTemporary = !FileManager.default.fileExists(atPath: source.source)
        let unzipStart = ProcessInfo.processInfo.systemUptime
        let package = try XLSXPackage(xlsxURL: workbookURL)
        let unzipSeconds = ProcessInfo.processInfo.systemUptime - unzipStart
        defer {
            package.cleanup()
            if isTemporary {
                try? FileManager.default.removeItem(at: workbookURL)
            }
        }

        let xmlStart = ProcessInfo.processInfo.systemUptime
        let workbookData = try package.data(at: "xl/workbook.xml")
        let relsData = try package.data(at: "xl/_rels/workbook.xml.rels")
        let sharedStringsData = (try? package.data(at: "xl/sharedStrings.xml")) ?? Data()

        let workbookSheets = WorkbookParser().parse(data: workbookData)
        let relationships = RelationshipParser().parse(data: relsData)
        let sharedStrings = SharedStringsParser().parse(data: sharedStringsData)

        let calendar = Calendar(identifier: .gregorian)

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

        let xmlSeconds = ProcessInfo.processInfo.systemUptime - xmlStart
        let rulesStart = ProcessInfo.processInfo.systemUptime
        let ruleOccurrences = try Self.extractRuleOccurrences(
            source: source,
            workdayHours: workdayHours,
            sheets: parsedSheets,
            calendar: calendar,
            timeZone: timeZone
        )

        let rulesSeconds = ProcessInfo.processInfo.systemUptime - rulesStart
        let parserStart = ProcessInfo.processInfo.systemUptime
        let parserSelection = try await chooseOccurrences(
            source: source,
            workdayHours: workdayHours,
            parserMode: parserMode,
            aiConfiguration: aiConfiguration,
            parsedSheets: parsedSheets,
            ruleOccurrences: ruleOccurrences,
            timeZone: timeZone
        )

        let parserSeconds = ProcessInfo.processInfo.systemUptime - parserStart
        let mergeStart = ProcessInfo.processInfo.systemUptime
        var occurrences = parserSelection.occurrences
        let parserLabel = parserSelection.label
        let parserNotes = parserSelection.notes

        occurrences.sort { $0.start < $1.start }
        let allEvents = mergeReservationOccurrences(occurrences: occurrences, source: source)
        let filteredEvents: [ReservationEvent]
        if upcomingOnly {
            filteredEvents = futureOnlyEvents(from: allEvents, referenceDate: referenceDate)
        } else {
            filteredEvents = allEvents
        }
        var extraction = ExtractionResult(
            allEvents: allEvents,
            filteredEvents: filteredEvents,
            filteredPastCount: max(allEvents.count - filteredEvents.count, 0),
            parserLabel: parserLabel,
            parserNotes: parserNotes,
            reviewRequired: parserSelection.reviewRequired,
            workbookFingerprint: parserSelection.workbookFingerprint,
            averageConfidence: parserSelection.averageConfidence,
            minimumConfidence: parserSelection.minimumConfidence
        )
        extraction.performanceTimings = [
            "download": downloadSeconds,
            "unzip": unzipSeconds,
            "xlsx": xmlSeconds,
            "rules": rulesSeconds,
            "parser": parserSeconds,
            "merge": ProcessInfo.processInfo.systemUptime - mergeStart
        ]
        return extraction
    }

    private func extractImageSource(
        source: SourceItem,
        workdayHours: WorkdayHours,
        upcomingOnly: Bool,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        imageURL: URL,
        timeZone: TimeZone,
        referenceDate: Date
    ) async throws -> ExtractionResult {
        if let localResult = try localImageParser.parse(
            source: source,
            workdayHours: workdayHours,
            imageURL: imageURL,
            timeZone: timeZone
        ) {
            let occurrences = localResult.occurrences.sorted { $0.start < $1.start }
            let allEvents = mergeReservationOccurrences(occurrences: occurrences, source: source)
            let filteredEvents: [ReservationEvent]
            if upcomingOnly {
                filteredEvents = futureOnlyEvents(from: allEvents, referenceDate: referenceDate)
            } else {
                filteredEvents = allEvents
            }

            return ExtractionResult(
                allEvents: allEvents,
                filteredEvents: filteredEvents,
                filteredPastCount: max(allEvents.count - filteredEvents.count, 0),
                parserLabel: "Local timetable image",
                parserNotes: localResult.notes,
                reviewRequired: false,
                workbookFingerprint: nil,
                averageConfidence: nil,
                minimumConfidence: nil
            )
        }

        guard parserMode != .rulesOnly else {
            throw AppFailure.invalidAIConfiguration("Image schedules require AI parsing. Change Parser Mode to Auto or AI.")
        }
        guard let aiConfiguration else {
            throw AppFailure.invalidAIConfiguration("Set an AI platform and API key before using an image source.")
        }
        guard aiConfiguration.provider.supportsImageParsing else {
            throw AppFailure.invalidAIConfiguration("The selected AI platform does not support image parsing yet. Use a platform marked '(images)' for image sources.")
        }
        let normalized = try await aiNormalizer.normalizeImage(
            source: source,
            workdayHours: workdayHours,
            imageURL: imageURL,
            configuration: aiConfiguration,
            timeZone: timeZone
        )
        let occurrences = normalized.occurrences.sorted { $0.start < $1.start }
        let allEvents = mergeReservationOccurrences(occurrences: occurrences, source: source)
        let filteredEvents: [ReservationEvent]
        if upcomingOnly {
            filteredEvents = futureOnlyEvents(from: allEvents, referenceDate: referenceDate)
        } else {
            filteredEvents = allEvents
        }

        return ExtractionResult(
            allEvents: allEvents,
            filteredEvents: filteredEvents,
            filteredPastCount: max(allEvents.count - filteredEvents.count, 0),
            parserLabel: "AI image parsing",
            parserNotes: normalized.notes,
            reviewRequired: normalized.reviewRequired,
            workbookFingerprint: normalized.workbookFingerprint,
            averageConfidence: normalized.averageConfidence,
            minimumConfidence: normalized.minimumConfidence
        )
    }

    private func chooseOccurrences(
        source: SourceItem,
        workdayHours: WorkdayHours,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        parsedSheets: [ParsedWorkbookSheet],
        ruleOccurrences: [SlotOccurrence],
        timeZone: TimeZone
    ) async throws -> ParserSelection {
        switch parserMode {
        case .rulesOnly:
            return ParserSelection(
                occurrences: ruleOccurrences,
                label: "Rule-based",
                notes: ["Used local slot and occupancy rules only."],
                reviewRequired: false,
                workbookFingerprint: nil,
                averageConfidence: nil,
                minimumConfidence: nil
            )
        case .auto:
            let autoStrategy = TimeWeaverCore.chooseAutoParserStrategy(
                ruleOccurrencesCount: ruleOccurrences.count,
                hasAIConfiguration: aiConfiguration != nil
            )
            if autoStrategy == .ruleBased {
                return ParserSelection(
                    occurrences: ruleOccurrences,
                    label: "Rule-based",
                    notes: ["Built-in workbook rules matched this source, so AI fallback was not needed."],
                    reviewRequired: false,
                    workbookFingerprint: nil,
                    averageConfidence: nil,
                    minimumConfidence: nil
                )
            }
            if autoStrategy == .ruleBasedNoAIConfiguration {
                return ParserSelection(
                    occurrences: ruleOccurrences,
                    label: "Rule-based",
                    notes: ["AI fallback is not configured, so only local rules were used."],
                    reviewRequired: false,
                    workbookFingerprint: nil,
                    averageConfidence: nil,
                    minimumConfidence: nil
                )
            }
            guard let aiConfiguration else {
                throw AppFailure.invalidAIConfiguration("AI parser is enabled but not configured.")
            }
            let normalized = try await aiNormalizer.normalize(
                source: source,
                workdayHours: workdayHours,
                sheets: parsedSheets,
                configuration: aiConfiguration,
                timeZone: timeZone
            )
            return ParserSelection(
                occurrences: normalized.occurrences,
                label: "AI normalization",
                notes: normalized.notes,
                reviewRequired: normalized.reviewRequired,
                workbookFingerprint: normalized.workbookFingerprint,
                averageConfidence: normalized.averageConfidence,
                minimumConfidence: normalized.minimumConfidence
            )
        case .aiOnly:
            guard let aiConfiguration else {
                throw AppFailure.invalidAIConfiguration("Set an endpoint URL, model, and API key before using AI mode.")
            }
            let normalized = try await aiNormalizer.normalize(
                source: source,
                workdayHours: workdayHours,
                sheets: parsedSheets,
                configuration: aiConfiguration,
                timeZone: timeZone
            )
            return ParserSelection(
                occurrences: normalized.occurrences,
                label: "AI normalization",
                notes: normalized.notes,
                reviewRequired: normalized.reviewRequired,
                workbookFingerprint: normalized.workbookFingerprint,
                averageConfidence: normalized.averageConfidence,
                minimumConfidence: normalized.minimumConfidence
            )
        }
    }

    private static func extractRuleOccurrences(
        source: SourceItem,
        workdayHours: WorkdayHours,
        sheets: [ParsedWorkbookSheet],
        calendar: Calendar,
        timeZone: TimeZone
    ) throws -> [SlotOccurrence] {
        var occurrences: [SlotOccurrence] = []
        for sheet in sheets {
            guard let year = sheet.year, let month = sheet.month else { continue }
            occurrences += try extractSheetOccurrences(
                worksheet: sheet.worksheet,
                source: source,
                sheetName: sheet.name,
                year: year,
                month: month,
                calendar: calendar,
                timeZone: timeZone,
                workdayHours: workdayHours
            )
        }
        return occurrences
    }

    private static func extractSheetOccurrences(
        worksheet: WorksheetParser,
        source: SourceItem,
        sheetName: String,
        year: Int,
        month: Int,
        calendar: Calendar,
        timeZone: TimeZone,
        workdayHours: WorkdayHours
    ) throws -> [SlotOccurrence] {
        var occurrences: [SlotOccurrence] = []

        for row in 1...worksheet.maxRow {
            var dayColumns: [Int: Int] = [:]
            for column in 1...worksheet.maxColumn {
                if let text = worksheet.cellsByRow[row]?[column], let day = dayNumber(from: text) {
                    dayColumns[column] = day
                }
            }
            if dayColumns.isEmpty { continue }

            let slotRows = matchingSlotRows(for: row, worksheet: worksheet)
            if !slotRows.isEmpty {
                occurrences += try extractPPMSSlotOccurrences(
                    sheetName: sheetName,
                    source: source,
                    dayColumns: dayColumns,
                    slotRows: slotRows,
                    year: year,
                    month: month,
                    calendar: calendar,
                    timeZone: timeZone,
                    worksheet: worksheet
                )
                continue
            }

            occurrences += extractDailyOccupancyOccurrences(
                workdayHours: workdayHours,
                sheetName: sheetName,
                source: source,
                dayColumns: dayColumns,
                dayRow: row,
                year: year,
                month: month,
                calendar: calendar,
                timeZone: timeZone,
                worksheet: worksheet
            )
        }

        return occurrences
    }

    private static func matchingSlotRows(
        for row: Int,
        worksheet: WorksheetParser
    ) -> [(SlotRule, Int)] {
        var slotRows: [(SlotRule, Int)] = []
        for offset in 1...6 {
            let label = worksheet.cellsByRow[row + offset]?[1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let rule = inferredSlotRule(from: label) {
                slotRows.append((rule, row + offset))
                continue
            }
            if !slotRows.isEmpty {
                break
            }
        }
        return slotRows
    }

    private static func extractPPMSSlotOccurrences(
        sheetName: String,
        source: SourceItem,
        dayColumns: [Int: Int],
        slotRows: [(SlotRule, Int)],
        year: Int,
        month: Int,
        calendar: Calendar,
        timeZone: TimeZone,
        worksheet: WorksheetParser
    ) throws -> [SlotOccurrence] {
        var occurrences: [SlotOccurrence] = []

        for (column, day) in dayColumns {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.timeZone = timeZone
            guard let baseDate = calendar.date(from: components) else { continue }

            for (rule, slotRow) in slotRows {
                guard let value = worksheet.cellsByRow[slotRow]?[column],
                      source.matchesBookingID(value) else { continue }
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
                        sheetName: sheetName,
                        cellReference: reference,
                        slotLabel: rule.sheetLabel,
                        isAllDay: false
                    )
                )
            }
        }

        return occurrences
    }

    private static func extractDailyOccupancyOccurrences(
        workdayHours: WorkdayHours,
        sheetName: String,
        source: SourceItem,
        dayColumns: [Int: Int],
        dayRow: Int,
        year: Int,
        month: Int,
        calendar: Calendar,
        timeZone: TimeZone,
        worksheet: WorksheetParser
    ) -> [SlotOccurrence] {
        let occupancyRow = dayRow + 1
        let leadingLabel = worksheet.cellsByRow[occupancyRow]?[1]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if inferredSlotRule(from: leadingLabel) != nil {
            return []
        }

        let occupiedColumnCount = dayColumns.keys.reduce(into: 0) { count, column in
            if let value = worksheet.cellsByRow[occupancyRow]?[column],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        guard occupiedColumnCount > 0 else { return [] }

        var occurrences: [SlotOccurrence] = []
        for (column, day) in dayColumns {
            guard let value = worksheet.cellsByRow[occupancyRow]?[column],
                  source.matchesBookingID(value) else { continue }

            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.timeZone = timeZone
            guard let baseDate = calendar.date(from: components),
                  let range = buildWorkdayRange(
                    on: baseDate,
                    workdayHours: workdayHours,
                    calendar: calendar,
                    timeZone: timeZone
                  ) else { continue }

            let reference = "\(columnLetters(column))\(occupancyRow)"
            occurrences.append(
                SlotOccurrence(
                    start: range.0,
                    end: range.1,
                    sheetName: sheetName,
                    cellReference: reference,
                    slotLabel: "default-workday",
                    isAllDay: false
                )
            )
        }

        return occurrences
    }

    private static func inferredSlotRule(from label: String) -> SlotRule? {
        TimeWeaverCore.inferredSlotRule(from: label, builtinRules: builtinSlotRules())
    }

    private static func mergeOccurrences(occurrences: [SlotOccurrence], source: SourceItem) -> [ReservationEvent] {
        mergeReservationOccurrences(occurrences: occurrences, source: source)
    }
}

func sourceIdentity(for source: SourceItem) -> String {
    source.stableIdentity
}

func legacySourceIdentity(for source: SourceItem) -> String {
    source.legacyIdentity
}

func mergeReservationOccurrences(occurrences: [SlotOccurrence], source: SourceItem) -> [ReservationEvent] {
    let sourceID = sourceIdentity(for: source)
    let legacySourceID = legacySourceIdentity(for: source)
    var merged: [ReservationEvent] = []

    for occurrence in occurrences {
        if var current = merged.last, occurrence.isAllDay == current.isAllDay, occurrence.start <= current.end {
            current.end = max(current.end, occurrence.end)
            current.sheetNames.append(occurrence.sheetName)
            current.cellReferences.append(occurrence.cellReference)
            current.syncKey = digest("\(sourceID)|\(current.sheetNames.joined(separator: ","))|\(current.cellReferences.joined(separator: ","))")
            current.legacySyncKey = digest("\(legacySourceID)|\(current.sheetNames.joined(separator: ","))|\(current.cellReferences.joined(separator: ","))|\(source.bookingID)")
            merged[merged.count - 1] = current
        } else {
            let syncKey = digest("\(sourceID)|\(occurrence.sheetName)|\(occurrence.cellReference)")
            let legacySyncKey = digest("\(legacySourceID)|\(occurrence.sheetName)|\(occurrence.cellReference)|\(source.bookingID)")
            merged.append(
                ReservationEvent(
                    syncKey: syncKey,
                    legacySyncKey: legacySyncKey,
                    sourceID: sourceID,
                    sourceName: source.name,
                    sourceLink: source.source,
                    bookingID: source.bookingID,
                    calendarName: source.calendar,
                    start: occurrence.start,
                    end: occurrence.end,
                    isAllDay: occurrence.isAllDay,
                    sheetNames: [occurrence.sheetName],
                    cellReferences: [occurrence.cellReference]
                )
            )
        }
    }

    return merged
}

func futureOnlyEvents(
    from events: [ReservationEvent],
    referenceDate: Date
) -> [ReservationEvent] {
    events.filter { $0.end >= referenceDate }
}
