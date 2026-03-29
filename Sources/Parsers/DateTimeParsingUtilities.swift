import Foundation

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

func parseMonthSheet(_ title: String) -> (Int, Int)? {
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

func dayNumber(from text: String) -> Int? {
    if let value = Int(text) {
        return (1...31).contains(value) ? value : nil
    }
    if let value = Double(text), value.rounded() == value {
        let intValue = Int(value)
        return (1...31).contains(intValue) ? intValue : nil
    }
    return nil
}

func decodeCellReference(_ reference: String) -> (Int, Int)? {
    let letters = reference.prefix { $0.isLetter }
    let numbers = String(reference.reversed().prefix { $0.isNumber }.reversed())
    guard !letters.isEmpty, let row = Int(numbers) else { return nil }
    var column = 0
    for scalar in letters.uppercased().unicodeScalars {
        column = column * 26 + Int(scalar.value) - 64
    }
    return (row, column)
}

func columnLetters(_ value: Int) -> String {
    var value = value
    var output = ""
    while value > 0 {
        let remainder = (value - 1) % 26
        output = String(UnicodeScalar(65 + remainder)!) + output
        value = (value - 1) / 26
    }
    return output
}

func clockString(fromMinutes minutes: Int) -> String {
    let normalized = ((minutes % (24 * 60)) + (24 * 60)) % (24 * 60)
    let hour = normalized / 60
    let minute = normalized % 60
    return String(format: "%02d:%02d", hour, minute)
}

func buildWorkdayRange(
    on baseDate: Date,
    workdayHours: WorkdayHours,
    calendar: Calendar,
    timeZone: TimeZone
) -> (Date, Date)? {
    guard let start = try? buildDate(from: baseDate, timeString: workdayHours.start, in: timeZone),
          let rawEnd = try? buildDate(from: baseDate, timeString: workdayHours.end, in: timeZone) else {
        return nil
    }
    let end = rawEnd > start ? rawEnd : (calendar.date(byAdding: .day, value: 1, to: rawEnd) ?? rawEnd)
    return (start, end)
}

func buildDate(from baseDate: Date, timeString: String, in timeZone: TimeZone) throws -> Date {
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

func parseFlexibleISO8601(_ value: String, timeZone: TimeZone) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: trimmed) {
        return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: trimmed) {
        return date
    }

    let dateOnly = DateFormatter()
    dateOnly.calendar = Calendar(identifier: .gregorian)
    dateOnly.timeZone = timeZone
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.dateFormat = "yyyy-MM-dd"
    return dateOnly.date(from: trimmed)
}
