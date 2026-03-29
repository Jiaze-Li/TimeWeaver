import Foundation
import EventKit

private struct ReservationExtractor {
    static func extract(
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

        let ruleOccurrences = try extractRuleOccurrences(
            source: source,
            workdayHours: workdayHours,
            sheets: parsedSheets,
            calendar: calendar,
            timeZone: timeZone
        )

        let parserSelection = try await chooseOccurrences(
            source: source,
            workdayHours: workdayHours,
            parserMode: parserMode,
            aiConfiguration: aiConfiguration,
            parsedSheets: parsedSheets,
            ruleOccurrences: ruleOccurrences,
            timeZone: timeZone
        )

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
        return ExtractionResult(
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
    }

    private static func extractImageSource(
        source: SourceItem,
        workdayHours: WorkdayHours,
        upcomingOnly: Bool,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        imageURL: URL,
        timeZone: TimeZone,
        referenceDate: Date
    ) async throws -> ExtractionResult {
        if let localResult = try LocalTimetableImageParser.parse(
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
        let normalized = try await AIWorkbookNormalizer.normalizeImage(
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

    private static func chooseOccurrences(
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
            let normalized = try await AIWorkbookNormalizer.normalize(
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
            let normalized = try await AIWorkbookNormalizer.normalize(
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
                  value.caseInsensitiveCompare(source.bookingID) == .orderedSame else { continue }

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
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        if let builtin = builtinSlotRules().first(where: {
            $0.sheetLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }) {
            return builtin
        }

        guard let range = parseSlotRange(from: normalized) else {
            return nil
        }
        return SlotRule(
            sheetLabel: label,
            start: range.start,
            end: range.end,
            endsNextDay: range.endsNextDay
        )
    }

    private static func parseSlotRange(from label: String) -> (start: String, end: String, endsNextDay: Bool)? {
        let normalized = label
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
            .replacingOccurrences(of: " ", with: "")
        let parts = normalized.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let startCandidates = resolvedTimeCandidates(from: parts[0]),
              let endCandidates = resolvedTimeCandidates(from: parts[1]) else {
            return nil
        }

        let best = startCandidates.flatMap { start in
            endCandidates.map { end -> (start: Int, end: Int, duration: Int) in
                let duration = end > start ? end - start : (24 * 60 - start) + end
                return (start: start, end: end, duration: duration)
            }
        }
        .filter { $0.duration > 0 }
        .sorted {
            if ($0.duration <= 16 * 60) != ($1.duration <= 16 * 60) {
                return $0.duration <= 16 * 60
            }
            return $0.duration < $1.duration
        }
        .first

        guard let best else { return nil }
        return (
            start: clockString(fromMinutes: best.start),
            end: clockString(fromMinutes: best.end),
            endsNextDay: best.end <= best.start
        )
    }

    private static func resolvedTimeCandidates(from token: String) -> [Int]? {
        let pattern = #"^(\d{1,2})(?::(\d{2}))?([ap]m)?$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
              let hourRange = Range(match.range(at: 1), in: token) else {
            return nil
        }
        let minuteRange = Range(match.range(at: 2), in: token)
        let meridiemRange = Range(match.range(at: 3), in: token)

        guard let hour = Int(token[hourRange]) else { return nil }
        let minute = minuteRange.flatMap { Int(token[$0]) } ?? 0
        guard (0...59).contains(minute) else { return nil }

        if let meridiemRange {
            let meridiem = token[meridiemRange]
            guard (1...12).contains(hour) else { return nil }
            let normalizedHour: Int
            if meridiem == "am" {
                normalizedHour = hour == 12 ? 0 : hour
            } else {
                normalizedHour = hour == 12 ? 12 : hour + 12
            }
            return [normalizedHour * 60 + minute]
        }

        guard (0...23).contains(hour) else { return nil }
        if hour == 0 || hour >= 13 {
            return [hour * 60 + minute]
        }
        return [hour * 60 + minute, (hour + 12) * 60 + minute]
    }

    private static func mergeOccurrences(occurrences: [SlotOccurrence], source: SourceItem) -> [ReservationEvent] {
        mergeReservationOccurrences(occurrences: occurrences, source: source)
    }
}

func sourceIdentity(for source: SourceItem) -> String {
    digest("\(source.name)|\(source.source)|\(source.bookingID)|\(source.calendar)")
}

private func mergeReservationOccurrences(occurrences: [SlotOccurrence], source: SourceItem) -> [ReservationEvent] {
    let sourceID = sourceIdentity(for: source)
    var merged: [ReservationEvent] = []

    for occurrence in occurrences {
        if var current = merged.last, occurrence.isAllDay == current.isAllDay, occurrence.start <= current.end {
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
                    isAllDay: occurrence.isAllDay,
                    sheetNames: [occurrence.sheetName],
                    cellReferences: [occurrence.cellReference]
                )
            )
        }
    }

    return merged
}

private func futureOnlyEvents(
    from events: [ReservationEvent],
    referenceDate: Date
) -> [ReservationEvent] {
    events.filter { $0.end >= referenceDate }
}

actor CalendarSyncEngine {
    private let store = EKEventStore()

    func calendarAccessState() -> CalendarAccessState {
        currentCalendarAccessState()
    }

    func calendarNamesIfAuthorized() -> [String]? {
        guard currentCalendarAccessState().hasUsableAccess else {
            return nil
        }
        return store.calendars(for: .event)
            .map(\.title)
            .sorted()
    }

    func requestCalendarAccess() async throws {
        try await ensureAccess()
    }

    func calendarNames() async throws -> [String] {
        try await ensureAccess()
        return store.calendars(for: .event)
            .map(\.title)
            .sorted()
    }

    func sync(
        sources: [SourceItem],
        workdayHours: WorkdayHours,
        upcomingOnly: Bool,
        previewOnly: Bool,
        parserMode: ParserMode,
        aiConfiguration: AIServiceConfiguration?,
        aiApprovals: [AIApprovalRecord],
        schedulingTimeZoneIdentifier: String,
        titleOverrides: [Date: String] = [:]
    ) async throws -> SyncRunResult {
        try await ensureAccess()
        let schedulingTimeZone = TimeZone(identifier: schedulingTimeZoneIdentifier) ?? .current
        let referenceDate = Date()
        var state = SettingsStore.loadState()
        var reports: [SourceSyncReport] = []
        var lines: [String] = []

        for source in sources where source.enabled {
            do {
                let extraction = try await ReservationExtractor.extract(
                    source: source,
                    workdayHours: workdayHours,
                    upcomingOnly: upcomingOnly,
                    parserMode: parserMode,
                    aiConfiguration: aiConfiguration,
                    timeZone: schedulingTimeZone,
                    referenceDate: referenceDate
                )
                let report = try syncSource(
                    source: source,
                    extraction: extraction,
                    state: &state,
                    upcomingOnly: upcomingOnly,
                    previewOnly: previewOnly,
                    aiApprovals: aiApprovals,
                    titleOverrides: titleOverrides
                )
                reports.append(report)

                lines.append("Source: \(report.sourceName)")
                if report.reviewRequired {
                    lines.append("Approval is required before this source can sync automatically.")
                }
                lines.append("Found \(report.totalMatchedCount) matching \(report.totalMatchedCount == 1 ? "booking" : "bookings").")

                let createStatus = previewOnly ? "would create" : "created"
                let updateStatus = previewOnly ? "would update" : "updated"
                let deleteStatus = previewOnly ? "would delete" : "deleted"
                let createCount = report.actions.filter { $0.status == createStatus }.count
                let updateCount = report.actions.filter { $0.status == updateStatus }.count
                let deleteCount = report.actions.filter { $0.status == deleteStatus }.count
                let unchangedCount = report.actions.filter { $0.status == "unchanged" }.count

                if report.filteredPastCount > 0 {
                    lines.append("Skipped \(report.filteredPastCount) past \(report.filteredPastCount == 1 ? "booking" : "bookings").")
                }

                if createCount > 0 {
                    lines.append(previewOnly ? "Ready to add \(createCount) future \(createCount == 1 ? "event" : "events")." : "Added \(createCount) future \(createCount == 1 ? "event" : "events").")
                }
                if updateCount > 0 {
                    lines.append(previewOnly ? "Ready to update \(updateCount) future \(updateCount == 1 ? "event" : "events")." : "Updated \(updateCount) future \(updateCount == 1 ? "event" : "events").")
                }
                if deleteCount > 0 {
                    lines.append(previewOnly ? "Ready to remove \(deleteCount) future \(deleteCount == 1 ? "event" : "events")." : "Removed \(deleteCount) future \(deleteCount == 1 ? "event" : "events").")
                }
                if createCount == 0 && updateCount == 0 && deleteCount == 0 {
                    if unchangedCount > 0 {
                        lines.append("Future calendar is already up to date.")
                    } else {
                        lines.append(previewOnly ? "No future events need to be added right now." : "No calendar changes were needed.")
                    }
                }

                let changedActions = report.actions.filter { $0.status != "unchanged" }
                if !changedActions.isEmpty {
                    lines.append(previewOnly ? "Planned changes:" : "Completed changes:")
                    for action in changedActions {
                        lines.append("- \(customerFacingInterval(start: action.start, end: action.end))")
                    }
                }
                lines.append("")
            } catch {
                let message = error.localizedDescription
                let report = SourceSyncReport(
                    sourceItemID: source.id,
                    sourceName: source.name,
                    bookingID: source.bookingID,
                    calendarName: source.calendar,
                    parserLabel: "Failed",
                    parserNotes: [],
                    reviewRequired: false,
                    workbookFingerprint: nil,
                    averageConfidence: nil,
                    minimumConfidence: nil,
                    totalMatchedCount: 0,
                    syncedMatchedCount: 0,
                    filteredPastCount: 0,
                    actions: [],
                    deleteCandidates: [],
                    errorMessage: message
                )
                reports.append(report)
                lines.append("Source: \(source.name)")
                lines.append("Could not complete sync for this source.")
                lines.append("Reason: \(message)")
                lines.append("")
            }
        }

        if !previewOnly {
            SettingsStore.saveState(state)
        }
        return SyncRunResult(reports: reports, outputText: lines.joined(separator: "\n"))
    }

    private func syncSource(
        source: SourceItem,
        extraction: ExtractionResult,
        state: inout SyncState,
        upcomingOnly: Bool,
        previewOnly: Bool,
        aiApprovals: [AIApprovalRecord],
        titleOverrides: [Date: String] = [:]
    ) throws -> SourceSyncReport {
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == source.calendar }) else {
            throw AppFailure.calendarNotFound(source.calendar)
        }

        if !previewOnly, extraction.reviewRequired {
            let sourceKey = sourceIdentity(for: source)
            let isApproved = aiApprovals.contains {
                $0.sourceKey == sourceKey && $0.workbookFingerprint == extraction.workbookFingerprint
            }
            if !isApproved {
                throw AppFailure.syncFailed("AI parse needs review first. Run Preview, then click Approve AI before Sync.")
            }
        }

        var actions: [EventAction] = []
        let events = extraction.filteredEvents
        let activeKeys = Set(events.map(\.syncKey))

        for event in events {
            let customURL = URL(string: "ppms-sync://event/\(event.syncKey)")!
            let existingRecord = state.events[event.syncKey]
            let existingEvent = findExistingEvent(for: event, stateRecord: existingRecord, calendar: calendar, customURL: customURL)
            let target = existingEvent ?? EKEvent(eventStore: store)
            let oldSignature = existingEvent.map(eventSignature) ?? ""

            let resolvedTitle = titleOverrides[event.start] ?? event.sourceName
            target.calendar = calendar
            target.title = resolvedTitle
            target.startDate = event.start
            target.endDate = event.end
            target.isAllDay = event.isAllDay
            target.notes = event.sourceLink
            target.url = customURL

            let newSignature = eventSignature(target)
            let status: String
            let mutation = TimeWeaverCore.determineUpsertMutation(
                hasExistingEvent: existingEvent != nil,
                oldSignature: oldSignature,
                newSignature: newSignature
            )
            if mutation == .create {
                status = previewOnly ? "would create" : "created"
                if !previewOnly {
                    try store.save(target, span: .thisEvent, commit: true)
                }
            } else if mutation == .update {
                status = previewOnly ? "would update" : "updated"
                if !previewOnly {
                    try store.save(target, span: .thisEvent, commit: true)
                }
            } else {
                status = "unchanged"
            }

            actions.append(EventAction(status: status, title: resolvedTitle, start: event.start, end: event.end))
            if !previewOnly, let identifier = target.eventIdentifier {
                state.events[event.syncKey] = StoredEvent(
                    eventIdentifier: identifier,
                    sourceID: event.sourceID,
                    calendar: event.calendarName,
                    title: resolvedTitle,
                    startISO: iso8601(event.start),
                    endISO: iso8601(event.end)
                )
            }
        }

        let staleEntries = state.events.compactMap { key, value -> DeleteCandidate? in
            guard TimeWeaverCore.shouldDeleteTrackedEvent(
                trackedSourceID: value.sourceID,
                requestedSourceID: sourceIdentity(for: source),
                syncKey: key,
                activeSyncKeys: activeKeys,
                trackedStartISO: value.startISO,
                upcomingOnly: upcomingOnly,
                now: Date(),
                timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current
            ) else { return nil }
            return DeleteCandidate(
                syncKey: key,
                eventIdentifier: value.eventIdentifier,
                title: value.title,
                startISO: value.startISO,
                endISO: value.endISO
            )
        }.sorted { $0.startISO < $1.startISO }

        var deleteCandidates: [DeleteCandidate] = []
        for candidate in staleEntries {
            if !previewOnly {
                if let event = findStaleEvent(candidate: candidate, calendar: calendar) {
                    try store.remove(event, span: .thisEvent, commit: true)
                }
                state.events.removeValue(forKey: candidate.syncKey)
            }
            if let start = parseFlexibleISO8601(candidate.startISO, timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current),
               let end = parseFlexibleISO8601(candidate.endISO, timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current) {
                actions.append(
                    EventAction(
                        status: previewOnly ? "would delete" : "deleted",
                        title: candidate.title,
                        start: start,
                        end: end
                    )
                )
            }
            deleteCandidates.append(candidate)
        }

        return SourceSyncReport(
            sourceItemID: source.id,
            sourceName: source.name,
            bookingID: source.bookingID,
            calendarName: source.calendar,
            parserLabel: extraction.parserLabel,
            parserNotes: extraction.parserNotes,
            reviewRequired: extraction.reviewRequired,
            workbookFingerprint: extraction.workbookFingerprint,
            averageConfidence: extraction.averageConfidence,
            minimumConfidence: extraction.minimumConfidence,
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

    private func findStaleEvent(candidate: DeleteCandidate, calendar: EKCalendar) -> EKEvent? {
        if let item = store.calendarItem(withIdentifier: candidate.eventIdentifier) as? EKEvent {
            return item
        }

        guard let start = parseFlexibleISO8601(candidate.startISO, timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current),
              let end = parseFlexibleISO8601(candidate.endISO, timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current) else {
            return nil
        }
        let predicate = store.predicateForEvents(
            withStart: Calendar.current.date(byAdding: .day, value: -2, to: start) ?? start,
            end: Calendar.current.date(byAdding: .day, value: 2, to: end) ?? end,
            calendars: [calendar]
        )
        let expectedURL = URL(string: "ppms-sync://event/\(candidate.syncKey)")
        return store.events(matching: predicate).first(where: { $0.url == expectedURL })
    }

    private func findEventForUndo(identifier: String, syncKey: String, start: Date, end: Date, calendar: EKCalendar) -> EKEvent? {
        if let item = store.calendarItem(withIdentifier: identifier) as? EKEvent {
            return item
        }
        let searchStart = Calendar.current.date(byAdding: .day, value: -2, to: start) ?? start
        let searchEnd = Calendar.current.date(byAdding: .day, value: 2, to: end) ?? end
        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: [calendar])
        let expectedURL = URL(string: "ppms-sync://event/\(syncKey)")
        return store.events(matching: predicate).first(where: { $0.url == expectedURL })
    }

    func revertImageImport(
        record: ImageImportUndoRecord,
        schedulingTimeZoneIdentifier: String
    ) async throws -> String {
        try await ensureAccess()
        let timeZone = TimeZone(identifier: schedulingTimeZoneIdentifier) ?? .current

        guard let calendar = store.calendars(for: .event).first(where: { $0.title == record.calendarName }) else {
            throw AppFailure.calendarNotFound(record.calendarName)
        }

        var state = SettingsStore.loadState()

        let beforeKeys = Set(record.beforeSnapshot.keys)
        let afterKeys = Set(record.afterSnapshot.keys)
        let createdKeys = afterKeys.subtracting(beforeKeys)
        let deletedKeys = beforeKeys.subtracting(afterKeys)
        let updatedKeys = beforeKeys.intersection(afterKeys).filter {
            record.beforeSnapshot[$0]?.eventIdentifier != record.afterSnapshot[$0]?.eventIdentifier
        }

        var removedCount = 0
        var restoredCount = 0

        for key in createdKeys {
            guard let stored = record.afterSnapshot[key],
                  let start = parseFlexibleISO8601(stored.startISO, timeZone: timeZone),
                  let end = parseFlexibleISO8601(stored.endISO, timeZone: timeZone) else { continue }
            if let ekEvent = findEventForUndo(identifier: stored.eventIdentifier, syncKey: key,
                                              start: start, end: end, calendar: calendar) {
                try store.remove(ekEvent, span: .thisEvent, commit: true)
                removedCount += 1
            }
            state.events.removeValue(forKey: key)
        }

        for key in deletedKeys {
            guard let stored = record.beforeSnapshot[key],
                  let start = parseFlexibleISO8601(stored.startISO, timeZone: timeZone),
                  let end = parseFlexibleISO8601(stored.endISO, timeZone: timeZone),
                  let customURL = URL(string: "ppms-sync://event/\(key)") else { continue }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = stored.title
            event.startDate = start
            event.endDate = end
            event.url = customURL
            try store.save(event, span: .thisEvent, commit: true)
            if let identifier = event.eventIdentifier {
                state.events[key] = StoredEvent(
                    eventIdentifier: identifier,
                    sourceID: stored.sourceID,
                    calendar: stored.calendar,
                    title: stored.title,
                    startISO: stored.startISO,
                    endISO: stored.endISO
                )
            }
            restoredCount += 1
        }

        for key in updatedKeys {
            guard let newStored = record.afterSnapshot[key],
                  let oldStored = record.beforeSnapshot[key],
                  let newStart = parseFlexibleISO8601(newStored.startISO, timeZone: timeZone),
                  let newEnd = parseFlexibleISO8601(newStored.endISO, timeZone: timeZone) else { continue }
            if let ekEvent = findEventForUndo(identifier: newStored.eventIdentifier, syncKey: key,
                                              start: newStart, end: newEnd, calendar: calendar) {
                try store.remove(ekEvent, span: .thisEvent, commit: true)
            }
            guard let start = parseFlexibleISO8601(oldStored.startISO, timeZone: timeZone),
                  let end = parseFlexibleISO8601(oldStored.endISO, timeZone: timeZone),
                  let customURL = URL(string: "ppms-sync://event/\(key)") else {
                state.events.removeValue(forKey: key)
                removedCount += 1
                continue
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = oldStored.title
            event.startDate = start
            event.endDate = end
            event.url = customURL
            try store.save(event, span: .thisEvent, commit: true)
            if let identifier = event.eventIdentifier {
                state.events[key] = StoredEvent(
                    eventIdentifier: identifier,
                    sourceID: oldStored.sourceID,
                    calendar: oldStored.calendar,
                    title: oldStored.title,
                    startISO: oldStored.startISO,
                    endISO: oldStored.endISO
                )
            }
            restoredCount += 1
        }

        SettingsStore.saveState(state)

        var parts: [String] = ["Import undone."]
        if removedCount > 0 {
            parts.append("Removed \(removedCount) \(removedCount == 1 ? "event" : "events").")
        }
        if restoredCount > 0 {
            parts.append("Restored \(restoredCount) \(restoredCount == 1 ? "event" : "events").")
        }
        return parts.joined(separator: " ")
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
