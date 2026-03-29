import Foundation
import AppKit

private struct LocalImageOCRWord {
    var page: Int
    var block: Int
    var paragraph: Int
    var line: Int
    var left: Int
    var top: Int
    var width: Int
    var height: Int
    var confidence: Double
    var text: String

    var right: Int { left + width }
    var bottom: Int { top + height }
    var centerX: Double { Double(left + width / 2) }
    var centerY: Double { Double(top + height / 2) }
    var lineKey: String { "\(page)-\(block)-\(paragraph)-\(line)" }
}

private struct LocalImageOCRLine {
    var left: Int
    var top: Int
    var words: [LocalImageOCRWord]
    var text: String
}

private struct LocalDateHeader {
    var text: String
    var date: Date
    var centerX: Double
    var centerY: Double
}

private struct LocalColorRGB {
    var red: Double
    var green: Double
    var blue: Double
}

private struct LocalColorComponent {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int
    var pixelCount: Int

    var centerX: Double { Double(left + right) / 2.0 }
    var centerY: Double { Double(top + bottom) / 2.0 }
}

struct LocalTimetableParseResult {
    var occurrences: [SlotOccurrence]
    var notes: [String]
}

struct ResolvedOccurrenceRange {
    var start: Date
    var end: Date
    var requiresReview: Bool
}

struct ParserSelection {
    var occurrences: [SlotOccurrence]
    var label: String
    var notes: [String]
    var reviewRequired: Bool
    var workbookFingerprint: String?
    var averageConfidence: Double?
    var minimumConfidence: Double?
}

struct ResponsesAPIEnvelope: Decodable {
    var outputText: String?
    var output: [ResponsesAPIOutput]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }
}

struct ResponsesAPIOutput: Decodable {
    var content: [ResponsesAPIContent]?
}

struct ResponsesAPIContent: Decodable {
    var type: String
    var text: String?
}

struct ChatCompletionsEnvelope: Decodable {
    var choices: [ChatCompletionChoice]
}

struct ChatCompletionChoice: Decodable {
    var message: ChatCompletionMessage
}

struct ChatCompletionMessage: Decodable {
    var content: String?
}

struct AnthropicMessagesEnvelope: Decodable {
    var content: [AnthropicContentBlock]
}

struct AnthropicContentBlock: Decodable {
    var type: String
    var text: String?
}

struct GeminiGenerateContentEnvelope: Decodable {
    var candidates: [GeminiCandidate]?
}

struct GeminiCandidate: Decodable {
    var content: GeminiContent?
}

struct GeminiContent: Decodable {
    var parts: [GeminiPart]?
}

struct GeminiPart: Decodable {
    var text: String?
}

struct LocalTimetableImageParser {
    private static var debugLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["PPMS_DEBUG_LOCAL_IMAGE"] == "1"
    }

    private static func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        fputs("[local-image] \(message)\n", stderr)
    }

    private struct BitmapSampler {
        let bitmap: NSBitmapImageRep
        let width: Int
        let height: Int

        init?(imageURL: URL) {
            guard let data = try? Data(contentsOf: imageURL),
                  let bitmap = NSBitmapImageRep(data: data) else {
                return nil
            }
            self.bitmap = bitmap
            self.width = bitmap.pixelsWide
            self.height = bitmap.pixelsHigh
        }

        func color(atX x: Int, y: Int) -> LocalColorRGB? {
            guard (0..<width).contains(x), (0..<height).contains(y) else {
                return nil
            }
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return nil
            }
            return LocalColorRGB(
                red: Double(color.redComponent * 255.0),
                green: Double(color.greenComponent * 255.0),
                blue: Double(color.blueComponent * 255.0)
            )
        }
    }

    static func parse(
        source: SourceItem,
        workdayHours: WorkdayHours,
        imageURL: URL,
        timeZone: TimeZone
    ) throws -> LocalTimetableParseResult? {
        guard let bitmap = BitmapSampler(imageURL: imageURL) else {
            return nil
        }
        let denseWords = try parseOCRWords(imageURL: imageURL, pageSegmentationMode: 11)
        guard !denseWords.isEmpty else {
            debugLog("No OCR words from PSM 11.")
            return nil
        }
        debugLog("PSM11 words: \(denseWords.count)")
        let rowWords = try parseOCRWords(imageURL: imageURL, pageSegmentationMode: 4)
        debugLog("PSM4 words: \(rowWords.count)")
        let dateRows = buildDateRows(from: denseWords, timeZone: timeZone)
        guard !dateRows.isEmpty else {
            debugLog("No date rows recognized.")
            return nil
        }
        debugLog("Date rows: \(dateRows.count)")
        guard let legendWord = findLegendWord(for: source.bookingID, in: denseWords) else {
            debugLog("Legend word for \(source.bookingID) not found. Trying text search fallback.")
            return textSearchResult(
                bookingID: source.bookingID,
                denseWords: denseWords,
                rowWords: rowWords,
                dateRows: dateRows,
                timeZone: timeZone
            )
        }
        debugLog("Legend word: \(legendWord.text) @ \(legendWord.left),\(legendWord.top)")
        guard let targetColor = sampleLegendColor(around: legendWord, bitmap: bitmap) else {
            debugLog("Legend color sampling failed.")
            return nil
        }
        debugLog(String(format: "Legend color: %.1f %.1f %.1f", targetColor.red, targetColor.green, targetColor.blue))
        let components = detectTargetComponents(
            bitmap: bitmap,
            targetColor: targetColor,
            minimumY: max(170, legendWord.bottom + 20)
        )
        guard !components.isEmpty else {
            debugLog("No target color components detected.")
            return nil
        }
        debugLog("Components: \(components.count)")
        let rowTemplates = buildRowTemplates(from: rowWords, dateRows: dateRows)
        debugLog("Row templates: \(rowTemplates.count)")
        var occurrences: [SlotOccurrence] = []

        for component in components {
            guard let weekRow = dateRows.last(where: { ($0.first?.centerY ?? 0) <= component.centerY }) else {
                debugLog("Could not map week row for component at \(Int(component.centerX)),\(Int(component.centerY)).")
                return nil
            }
            guard let dateHeader = weekRow.min(by: { abs($0.centerX - component.centerX) < abs($1.centerX - component.centerX) }) else {
                debugLog("Could not map date header for component at \(Int(component.centerX)),\(Int(component.centerY)).")
                return nil
            }
            let text = denseWords
                .filter { intersects(word: $0, component: component, padding: 16) }
                .sorted { lhs, rhs in
                    if lhs.top == rhs.top {
                        return lhs.left < rhs.left
                    }
                    return lhs.top < rhs.top
                }
                .map(\.text)
                .joined(separator: " ")

            var times = extractLooseClocks(from: text)
            debugLog("Raw \(dateHeader.text): \(text)")
            debugLog("Raw times \(dateHeader.text): \(times)")
            let weekRowY = weekRow.first?.centerY ?? component.centerY
            let template = preferredRowTemplate(
                for: component,
                weekRowY: weekRowY,
                templates: rowTemplates
            )
            if times.count < 2 {
                if let template {
                    debugLog("Template \(dateHeader.text): \(template.start)-\(template.end)")
                    if times.isEmpty {
                        times = [template.start, template.end]
                    } else {
                        times = deduplicatedSortedClocks(times + [template.start, template.end])
                    }
                }
            }
            let resolvedClocks = resolveComponentClocks(
                extracted: times,
                template: template
            )
            debugLog("Resolved times \(dateHeader.text): \(resolvedClocks.map { [$0.start, $0.end] } ?? [])")
            guard let resolvedClocks else {
                debugLog("Could not resolve times for \(dateHeader.text) component text: \(text)")
                return nil
            }
            let startClock = resolvedClocks.start
            let endClock = resolvedClocks.end
            guard let start = try? buildDate(from: dateHeader.date, timeString: startClock, in: timeZone),
                  let rawEnd = try? buildDate(from: dateHeader.date, timeString: endClock, in: timeZone) else {
                return nil
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let end = rawEnd > start ? rawEnd : (calendar.date(byAdding: .day, value: 1, to: rawEnd) ?? rawEnd)
            occurrences.append(
                SlotOccurrence(
                    start: start,
                    end: end,
                    sheetName: "image",
                    cellReference: "\(Int(component.centerX))x\(Int(component.centerY))",
                    slotLabel: "local-image",
                    isAllDay: false
                )
            )
            debugLog("Mapped \(dateHeader.text) -> \(startClock)-\(endClock)")
        }

        guard occurrences.count == components.count else {
            debugLog("Occurrence count mismatch: \(occurrences.count) vs \(components.count)")
            return nil
        }
        occurrences.sort { $0.start < $1.start }
        return LocalTimetableParseResult(
            occurrences: occurrences,
            notes: [
                "Recognized a structured color-coded timetable locally for more consistent image extraction.",
                "Matched \(occurrences.count) lesson(s) using the legend color and OCR date/time anchors."
            ]
        )
    }

    private static func parseOCRWords(
        imageURL: URL,
        pageSegmentationMode: Int
    ) throws -> [LocalImageOCRWord] {
        guard let tesseractPath = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tesseractPath)
        process.arguments = [
            imageURL.path,
            "stdout",
            "-l", Self.availableOCRLanguages(),
            "--psm", String(pageSegmentationMode),
            "tsv"
        ]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let tsv = String(data: data, encoding: .utf8) else {
            return []
        }

        return tsv
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .compactMap { line -> LocalImageOCRWord? in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard columns.count >= 12, columns[0] == "5" else {
                    return nil
                }
                guard
                    let page = Int(columns[1]),
                    let block = Int(columns[2]),
                    let paragraph = Int(columns[3]),
                    let line = Int(columns[4]),
                    let left = Int(columns[6]),
                    let top = Int(columns[7]),
                    let width = Int(columns[8]),
                    let height = Int(columns[9]),
                    let confidence = Double(columns[10])
                else {
                    return nil
                }
                let text = columns[11].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }
                return LocalImageOCRWord(
                    page: page,
                    block: block,
                    paragraph: paragraph,
                    line: line,
                    left: left,
                    top: top,
                    width: width,
                    height: height,
                    confidence: confidence,
                    text: text
                )
            }
    }

    private static func buildDateRows(
        from words: [LocalImageOCRWord],
        timeZone: TimeZone
    ) -> [[LocalDateHeader]] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/M/d"

        let headers = words.compactMap { word -> LocalDateHeader? in
            guard word.text.range(of: #"^20\d{2}/\d{1,2}/\d{1,2}$"#, options: .regularExpression) != nil,
                  let date = formatter.date(from: word.text) else {
                return nil
            }
            return LocalDateHeader(
                text: word.text,
                date: date,
                centerX: word.centerX,
                centerY: word.centerY
            )
        }
        .sorted { lhs, rhs in
            if lhs.centerY == rhs.centerY {
                return lhs.centerX < rhs.centerX
            }
            return lhs.centerY < rhs.centerY
        }

        var rows: [[LocalDateHeader]] = []
        for header in headers {
            if rows.isEmpty || abs((rows.last?.first?.centerY ?? 0) - header.centerY) > 40 {
                rows.append([header])
            } else {
                rows[rows.count - 1].append(header)
            }
        }
        return rows.map { $0.sorted { $0.centerX < $1.centerX } }
    }

    private static func findLegendWord(
        for bookingID: String,
        in words: [LocalImageOCRWord]
    ) -> LocalImageOCRWord? {
        let target = normalizedLetters(bookingID)
        guard !target.isEmpty else {
            return nil
        }
        return words
            .filter { normalizedLetters($0.text).contains(target) || normalizedLetters($0.text).hasSuffix(target) }
            .max(by: { lhs, rhs in lhs.confidence < rhs.confidence })
    }

    private static func sampleLegendColor(
        around word: LocalImageOCRWord,
        bitmap: BitmapSampler
    ) -> LocalColorRGB? {
        var samples: [LocalColorRGB] = []
        let xRange = max(0, word.left - 16)...min(bitmap.width - 1, word.right + 16)
        let yRange = max(0, word.top - 8)...min(bitmap.height - 1, word.bottom + 8)
        for y in stride(from: yRange.lowerBound, through: yRange.upperBound, by: 2) {
            for x in stride(from: xRange.lowerBound, through: xRange.upperBound, by: 2) {
                guard let color = bitmap.color(atX: x, y: y) else { continue }
                let brightness = color.red + color.green + color.blue
                if brightness < 740 && max(color.red, color.green, color.blue) > 120 {
                    samples.append(color)
                }
            }
        }
        guard !samples.isEmpty else {
            return nil
        }
        let count = Double(samples.count)
        return LocalColorRGB(
            red: samples.reduce(0) { $0 + $1.red } / count,
            green: samples.reduce(0) { $0 + $1.green } / count,
            blue: samples.reduce(0) { $0 + $1.blue } / count
        )
    }

    private static func detectTargetComponents(
        bitmap: BitmapSampler,
        targetColor: LocalColorRGB,
        minimumY: Int
    ) -> [LocalColorComponent] {
        let step = 4
        let gridWidth = (bitmap.width + step - 1) / step
        let gridHeight = (bitmap.height + step - 1) / step
        var mask = Array(repeating: false, count: gridWidth * gridHeight)

        for gridY in 0..<gridHeight {
            let y = min(bitmap.height - 1, gridY * step + step / 2)
            for gridX in 0..<gridWidth {
                let x = min(bitmap.width - 1, gridX * step + step / 2)
                guard let color = bitmap.color(atX: x, y: y) else { continue }
                if colorDistance(color, targetColor) < 70, y > minimumY {
                    mask[gridY * gridWidth + gridX] = true
                }
            }
        }

        var visited = Array(repeating: false, count: mask.count)
        var components: [LocalColorComponent] = []

        for gridY in 0..<gridHeight {
            for gridX in 0..<gridWidth {
                let startIndex = gridY * gridWidth + gridX
                guard mask[startIndex], !visited[startIndex] else { continue }
                var queue = [(gridX, gridY)]
                visited[startIndex] = true
                var positions: [(Int, Int)] = []
                var cursor = 0

                while cursor < queue.count {
                    let (currentX, currentY) = queue[cursor]
                    cursor += 1
                    positions.append((currentX, currentY))

                    let neighbors = [
                        (currentX + 1, currentY),
                        (currentX - 1, currentY),
                        (currentX, currentY + 1),
                        (currentX, currentY - 1)
                    ]
                    for (nextX, nextY) in neighbors {
                        guard (0..<gridWidth).contains(nextX), (0..<gridHeight).contains(nextY) else { continue }
                        let nextIndex = nextY * gridWidth + nextX
                        guard mask[nextIndex], !visited[nextIndex] else { continue }
                        visited[nextIndex] = true
                        queue.append((nextX, nextY))
                    }
                }

                guard positions.count >= 80 else { continue }
                let minX = positions.map(\.0).min() ?? 0
                let maxX = positions.map(\.0).max() ?? 0
                let minY = positions.map(\.1).min() ?? 0
                let maxY = positions.map(\.1).max() ?? 0
                components.append(
                    LocalColorComponent(
                        left: minX * step,
                        top: minY * step,
                        right: maxX * step,
                        bottom: maxY * step,
                        pixelCount: positions.count
                    )
                )
            }
        }

        return components.sorted {
            if $0.top == $1.top {
                return $0.left < $1.left
            }
            return $0.top < $1.top
        }
    }

    private static func buildRowTemplates(
        from words: [LocalImageOCRWord],
        dateRows: [[LocalDateHeader]]
    ) -> [(offset: Double, start: String, end: String)] {
        let grouped = Dictionary(grouping: words, by: \.lineKey)
        return grouped.values.compactMap { group in
            let sorted = group.sorted { $0.left < $1.left }
            guard let left = sorted.map(\.left).min(), left < 250,
                  let top = sorted.map(\.top).min() else {
                return nil
            }
            let text = sorted.map(\.text).joined(separator: " ")
            let times = extractLooseClocks(from: text)
            guard times.count == 2,
                  let startMinutes = minutesSinceMidnight(times[0]),
                  let endMinutes = minutesSinceMidnight(times[1]),
                  startMinutes >= 6 * 60,
                  endMinutes > startMinutes else {
                return nil
            }
            guard let weekRow = dateRows.last(where: { ($0.first?.centerY ?? 0) <= Double(top) }) else {
                return nil
            }
            return (offset: Double(top) - (weekRow.first?.centerY ?? 0), start: times[0], end: times[1])
        }
    }

    private static func nearestRowTemplate(
        to relativeY: Double,
        templates: [(offset: Double, start: String, end: String)]
    ) -> (offset: Double, start: String, end: String)? {
        guard let candidate = templates.min(by: { abs($0.offset - relativeY) < abs($1.offset - relativeY) }) else {
            return nil
        }
        return abs(candidate.offset - relativeY) < 32 ? candidate : nil
    }

    private static func preferredRowTemplate(
        for component: LocalColorComponent,
        weekRowY: Double,
        templates: [(offset: Double, start: String, end: String)]
    ) -> (offset: Double, start: String, end: String)? {
        let topAligned = nearestRowTemplate(
            to: Double(component.top) - weekRowY + 10,
            templates: templates
        )
        if let topAligned {
            return topAligned
        }
        return nearestRowTemplate(
            to: component.centerY - weekRowY,
            templates: templates
        )
    }

    private static func resolveComponentClocks(
        extracted: [String],
        template: (offset: Double, start: String, end: String)?
    ) -> (start: String, end: String)? {
        let unique = deduplicatedSortedClocks(extracted)
        guard !unique.isEmpty else {
            guard let template else { return nil }
            return (template.start, template.end)
        }

        if unique.count == 1 {
            guard let template else { return nil }
            return (template.start, template.end)
        }

        guard let template else {
            return (unique[0], unique[unique.count - 1])
        }

        if unique.contains(template.start), unique.contains(template.end) {
            return (template.start, template.end)
        }

        let candidatePairs = unique.enumerated().flatMap { lhs in
            unique.enumerated().compactMap { rhs -> (String, String)? in
                guard rhs.offset > lhs.offset else { return nil }
                return (lhs.element, rhs.element)
            }
        }

        let templateStart = minutesSinceMidnight(template.start) ?? 0
        let templateEnd = minutesSinceMidnight(template.end) ?? 0
        let templateDuration = max(templateEnd - templateStart, 0)

        let bestPair = candidatePairs.min { lhs, rhs in
            scoreClockPair(lhs, templateStart: templateStart, templateEnd: templateEnd, templateDuration: templateDuration)
            < scoreClockPair(rhs, templateStart: templateStart, templateEnd: templateEnd, templateDuration: templateDuration)
        }

        guard let bestPair else {
            return (template.start, template.end)
        }

        let bestScore = scoreClockPair(
            bestPair,
            templateStart: templateStart,
            templateEnd: templateEnd,
            templateDuration: templateDuration
        )

        if bestScore <= 150 {
            return bestPair
        }
        return (template.start, template.end)
    }

    private static func scoreClockPair(
        _ pair: (String, String),
        templateStart: Int,
        templateEnd: Int,
        templateDuration: Int
    ) -> Int {
        let start = minutesSinceMidnight(pair.0) ?? 0
        let end = minutesSinceMidnight(pair.1) ?? 0
        let duration = max(end - start, 0)
        return abs(start - templateStart) + abs(end - templateEnd) + abs(duration - templateDuration) * 2
    }

    private static func intersects(
        word: LocalImageOCRWord,
        component: LocalColorComponent,
        padding: Int
    ) -> Bool {
        let left = component.left - padding
        let right = component.right + padding
        let top = component.top - padding
        let bottom = component.bottom + padding
        return word.left >= left &&
            word.left <= right &&
            Int(word.centerY) >= top &&
            Int(word.centerY) <= bottom
    }

    private static func extractLooseClocks(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: ";", with: ":")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "o", with: "0")
            .replacingOccurrences(of: "i", with: "1")

        var clocks: [String] = []
        let standard = try! NSRegularExpression(pattern: #"(\d{1,2})[:](\d{2})"#)
        for match in standard.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            guard let hourRange = Range(match.range(at: 1), in: normalized),
                  let minuteRange = Range(match.range(at: 2), in: normalized),
                  let hour = Int(normalized[hourRange]),
                  let minute = Int(normalized[minuteRange]),
                  (0...23).contains(hour),
                  (0...59).contains(minute) else {
                continue
            }
            clocks.append(String(format: "%02d:%02d", hour, minute))
        }

        let compact = try! NSRegularExpression(pattern: #"(?<!\d)(\d{2})(\d{2})(?!\d)"#)
        for match in compact.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            guard let hourRange = Range(match.range(at: 1), in: normalized),
                  let minuteRange = Range(match.range(at: 2), in: normalized),
                  let hour = Int(normalized[hourRange]),
                  let minute = Int(normalized[minuteRange]),
                  (6...23).contains(hour),
                  [0, 15, 30, 45].contains(minute) else {
                continue
            }
            clocks.append(String(format: "%02d:%02d", hour, minute))
        }

        return deduplicatedSortedClocks(clocks)
    }

    private static func deduplicatedSortedClocks(_ clocks: [String]) -> [String] {
        var unique: [String] = []
        for clock in clocks {
            if !unique.contains(clock) {
                unique.append(clock)
            }
        }
        return unique.sorted {
            (minutesSinceMidnight($0) ?? 0) < (minutesSinceMidnight($1) ?? 0)
        }
    }

    private static func minutesSinceMidnight(_ clock: String) -> Int? {
        let pieces = clock.split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]),
              let minute = Int(pieces[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private static func textSearchResult(
        bookingID: String,
        denseWords: [LocalImageOCRWord],
        rowWords: [LocalImageOCRWord],
        dateRows: [[LocalDateHeader]],
        timeZone: TimeZone
    ) -> LocalTimetableParseResult? {
        let target = normalizedLetters(bookingID)
        guard !target.isEmpty else { return nil }
        let matchingWords = denseWords.filter { word in
            let n = normalizedLetters(word.text)
            return n.contains(target) || n.hasSuffix(target)
        }
        guard !matchingWords.isEmpty else {
            debugLog("Text search: no words matching '\(bookingID)'.")
            return nil
        }
        debugLog("Text search: \(matchingWords.count) word(s) matching '\(bookingID)'.")
        let rowTemplates = buildRowTemplates(from: rowWords, dateRows: dateRows)
        var occurrences: [SlotOccurrence] = []
        for word in matchingWords {
            guard let weekRow = dateRows.last(where: { ($0.first?.centerY ?? 0) <= word.centerY }),
                  let dateHeader = weekRow.min(by: { abs($0.centerX - word.centerX) < abs($1.centerX - word.centerX) })
            else {
                debugLog("Text search: no date header for '\(word.text)' at \(Int(word.centerX)),\(Int(word.centerY)).")
                continue
            }
            let nearbyText = denseWords
                .filter { $0.block == word.block && $0.paragraph == word.paragraph }
                .sorted { lhs, rhs in lhs.top == rhs.top ? lhs.left < rhs.left : lhs.top < rhs.top }
                .map(\.text)
                .joined(separator: " ")
            var times = extractLooseClocks(from: nearbyText)
            debugLog("Text search \(dateHeader.text): '\(nearbyText)' -> times \(times)")
            if times.count < 2 {
                let weekRowY = weekRow.first?.centerY ?? word.centerY
                let template = nearestRowTemplate(to: Double(word.top) - weekRowY + 10, templates: rowTemplates)
                    ?? nearestRowTemplate(to: word.centerY - weekRowY, templates: rowTemplates)
                if let template {
                    debugLog("Text search \(dateHeader.text): template \(template.start)-\(template.end)")
                    times = times.isEmpty ? [template.start, template.end]
                        : deduplicatedSortedClocks(times + [template.start, template.end])
                }
            }
            guard let resolved = resolveComponentClocks(extracted: times, template: nil),
                  let start = try? buildDate(from: dateHeader.date, timeString: resolved.start, in: timeZone),
                  let rawEnd = try? buildDate(from: dateHeader.date, timeString: resolved.end, in: timeZone)
            else {
                debugLog("Text search: could not resolve times for '\(word.text)' on \(dateHeader.text).")
                continue
            }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let end = rawEnd > start ? rawEnd : (cal.date(byAdding: .day, value: 1, to: rawEnd) ?? rawEnd)
            occurrences.append(SlotOccurrence(
                start: start,
                end: end,
                sheetName: "image",
                cellReference: "\(word.left)x\(word.top)",
                slotLabel: "local-image-text",
                isAllDay: false
            ))
            debugLog("Text search: matched \(dateHeader.text) -> \(resolved.start)-\(resolved.end)")
        }
        guard !occurrences.isEmpty else {
            debugLog("Text search: no occurrences resolved.")
            return nil
        }
        let deduped = occurrences.reduce(into: [SlotOccurrence]()) { result, occ in
            if !result.contains(where: { abs($0.start.timeIntervalSince(occ.start)) < 60 }) {
                result.append(occ)
            }
        }
        return LocalTimetableParseResult(
            occurrences: deduped.sorted { $0.start < $1.start },
            notes: [
                "Matched \(deduped.count) lesson(s) by scanning for '\(bookingID)' text directly in the timetable.",
                "No legend color found — results are based on direct text position in the grid."
            ]
        )
    }

    private static func availableOCRLanguages() -> String {
        let tessDataDirs = [
            "/opt/homebrew/share/tessdata",
            "/usr/local/share/tessdata",
            "/usr/share/tessdata"
        ]
        let hasChinese = tessDataDirs.contains {
            FileManager.default.fileExists(atPath: "\($0)/chi_sim.traineddata")
        }
        return hasChinese ? "chi_sim+eng" : "eng"
    }

    private static func normalizedLetters(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func colorDistance(_ lhs: LocalColorRGB, _ rhs: LocalColorRGB) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }
}
