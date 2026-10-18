import Foundation
import CryptoKit
import EventKit
#if canImport(TimeWeaverCore)
import TimeWeaverCore
#endif

func eventSignature(_ event: EKEvent) -> String {
    "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)|\(event.isAllDay)|\(event.notes ?? "")|\(event.url?.absoluteString ?? "")|\(event.calendar?.title ?? "")"
}

func proposedEventSignature(
    title: String,
    start: Date,
    end: Date,
    isAllDay: Bool,
    notes: String?,
    url: URL?,
    calendarTitle: String
) -> String {
    "\(title)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(isAllDay)|\(notes ?? "")|\(url?.absoluteString ?? "")|\(calendarTitle)"
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
    formatter.timeZone = TimeZone(identifier: defaultSchedulingTimeZoneIdentifier)
    return formatter.string(from: date)
}

func syncTimestampString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: defaultSchedulingTimeZoneIdentifier)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func customerFacingInterval(start: Date, end: Date) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let sameDay = calendar.isDate(start, inSameDayAs: end)

    let dayFormatter = DateFormatter()
    dayFormatter.calendar = calendar
    dayFormatter.timeZone = TimeZone(identifier: defaultSchedulingTimeZoneIdentifier)
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.dateFormat = "yyyy-MM-dd"

    let timeFormatter = DateFormatter()
    timeFormatter.calendar = calendar
    timeFormatter.timeZone = TimeZone(identifier: defaultSchedulingTimeZoneIdentifier)
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")
    timeFormatter.dateFormat = "HH:mm"

    let dateTimeFormatter = DateFormatter()
    dateTimeFormatter.calendar = calendar
    dateTimeFormatter.timeZone = TimeZone(identifier: defaultSchedulingTimeZoneIdentifier)
    dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm"

    if sameDay {
        return "\(dayFormatter.string(from: start)) \(timeFormatter.string(from: start))-\(timeFormatter.string(from: end))"
    }
    return "\(dateTimeFormatter.string(from: start)) -> \(dateTimeFormatter.string(from: end))"
}

func buildAutoReviewItems(from reports: [SourceSyncReport], existingState: SyncState) -> [AutoReviewChangeItem] {
    var items: [AutoReviewChangeItem] = []

    let tz = TimeZone(identifier: defaultSchedulingTimeZoneIdentifier) ?? .current
    for report in reports {
        for action in report.actions {
            guard ["would create", "would update", "would delete"].contains(action.status) else {
                continue
            }

            var oldStart: Date? = nil
            var oldEnd: Date? = nil
            if let stored = existingState.events[action.syncKey] {
                oldStart = parseFlexibleISO8601(stored.startISO, timeZone: tz)
                oldEnd = parseFlexibleISO8601(stored.endISO, timeZone: tz)
            }

            var newStart: Date? = nil
            var newEnd: Date? = nil
            if action.status != "would delete" {
                newStart = action.start
                newEnd = action.end
            }

            items.append(
                AutoReviewChangeItem(
                    sourceName: report.sourceName,
                    calendarName: report.calendarName,
                    status: action.status,
                    title: action.title,
                    oldStart: oldStart,
                    oldEnd: oldEnd,
                    newStart: newStart,
                    newEnd: newEnd,
                    syncKey: action.syncKey
                )
            )
        }
    }
    return items
}


/// syncKey is the reservation identity; fingerprint describes the current proposal.
func autoReviewFingerprint(for items: [AutoReviewChangeItem]) -> String {
    TimeWeaverCore.computeChangeFingerprint(
        items: items.map { item in
            (
                sourceName: item.sourceName,
                calendarName: item.calendarName,
                status: item.status,
                title: item.title,
                oldStartTimestamp: item.oldStart?.timeIntervalSince1970 ?? 0,
                oldEndTimestamp: item.oldEnd?.timeIntervalSince1970 ?? 0,
                newStartTimestamp: item.newStart?.timeIntervalSince1970 ?? 0,
                newEndTimestamp: item.newEnd?.timeIntervalSince1970 ?? 0,
                syncKey: item.syncKey
            )
        }
    )
}
func autoReviewItemFingerprint(_ item: AutoReviewChangeItem) -> String {
    autoReviewFingerprint(for: [item])
}

/// Migrates old batch Ignore entries, merging repeated bookings by syncKey.
/// The most recently ignored calendar/time/status wins without duplicating the booking.
func normalizedIgnoredReviews(_ records: [IgnoredAutoReview]) -> [IgnoredAutoReview] {
    var latest: [String: IgnoredAutoReview] = [:]
    for record in records {
        for item in record.items {
            if let existing = latest[item.syncKey], existing.ignoredAt >= record.ignoredAt {
                continue
            }
            latest[item.syncKey] = IgnoredAutoReview(
                fingerprint: autoReviewItemFingerprint(item),
                ignoredAt: record.ignoredAt,
                items: [item]
            )
        }
    }
    return latest.values.sorted {
        if $0.ignoredAt != $1.ignoredAt { return $0.ignoredAt > $1.ignoredAt }
        return $0.id < $1.id
    }
}

/// Suppress only identical ignored appointments; changes to other appointments
/// do not re-prompt unchanged ones. Review Again targets just one reservation.
func pendingAutoReviewItems(
    from allItems: [AutoReviewChangeItem],
    ignoredRecords: [IgnoredAutoReview],
    forceSyncKey: String? = nil
) -> [AutoReviewChangeItem] {
    let ignored = Dictionary(uniqueKeysWithValues: normalizedIgnoredReviews(ignoredRecords).compactMap { record in
        record.items.first.map { ($0.syncKey, record.fingerprint) }
    })
    return allItems.filter { item in
        if let forceSyncKey { return item.syncKey == forceSyncKey }
        return ignored[item.syncKey] != autoReviewItemFingerprint(item)
    }
}
