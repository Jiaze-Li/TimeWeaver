import Foundation
import CryptoKit
import EventKit

func eventSignature(_ event: EKEvent) -> String {
    "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)|\(event.isAllDay)|\(event.notes ?? "")|\(event.url?.absoluteString ?? "")|\(event.calendar?.title ?? "")"
}

func digest(_ text: String) -> String {
    TimeWeaverCore.fnv1a64Hex(text)
}

func deterministicUUID(for text: String) -> UUID {
    let hash = SHA256.hash(data: Data(text.utf8))
    var bytes = Array(hash.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    return formatter.string(from: date)
}

func syncTimestampString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func customerFacingInterval(start: Date, end: Date) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let sameDay = calendar.isDate(start, inSameDayAs: end)

    let dayFormatter = DateFormatter()
    dayFormatter.calendar = calendar
    dayFormatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.dateFormat = "yyyy-MM-dd"

    let timeFormatter = DateFormatter()
    timeFormatter.calendar = calendar
    timeFormatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")
    timeFormatter.dateFormat = "HH:mm"

    let dateTimeFormatter = DateFormatter()
    dateTimeFormatter.calendar = calendar
    dateTimeFormatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm"

    if sameDay {
        return "\(dayFormatter.string(from: start)) \(timeFormatter.string(from: start))-\(timeFormatter.string(from: end))"
    }
    return "\(dateTimeFormatter.string(from: start)) -> \(dateTimeFormatter.string(from: end))"
}
