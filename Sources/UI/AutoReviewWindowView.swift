import SwiftUI
import AppKit

struct AutoReviewWindowView: View {
    @EnvironmentObject var model: AppModel
    let review: PendingAutoReview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(review.items) { item in
                        AutoReviewItemRow(item: item)
                        Divider()
                            .padding(.leading, 38)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 380)
            Divider()
            footerView
        }
        .frame(minWidth: 560, minHeight: 280)
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review Calendar Changes")
                .font(.headline)
            HStack(spacing: 6) {
                Text("\(review.items.count) proposed \(review.items.count == 1 ? "change" : "changes")")
                    .foregroundStyle(.secondary)
                if !review.authorizedDeletionSourceIDs.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Label("Deletion protection warning", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footerView: some View {
        HStack {
            if !review.authorizedDeletionSourceIDs.isEmpty {
                Label("Unusual deletion detected: all bookings missing in source.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Button("Ignore") {
                model.ignoreAutoReview()
            }
            .keyboardShortcut(.cancelAction)

            Button("Accept All") {
                model.acceptAutoReview()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct AutoReviewItemRow: View {
    let item: AutoReviewChangeItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(item.status.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(statusColor)
                }

                HStack(spacing: 6) {
                    Text("Source: \(item.sourceName)")
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Calendar: \(item.calendarName)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                if let timeDescription = timeDescriptionText {
                    Text(timeDescription)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.85))
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var timeDescriptionText: String? {
        if item.status == "would update" {
            var parts: [String] = []
            if let oldStart = item.oldStart, let oldEnd = item.oldEnd {
                parts.append("Old: \(customerFacingInterval(start: oldStart, end: oldEnd))")
            }
            if let newStart = item.newStart, let newEnd = item.newEnd {
                parts.append("New: \(customerFacingInterval(start: newStart, end: newEnd))")
            }
            return parts.isEmpty ? nil : parts.joined(separator: "  →  ")
        } else if item.status == "would create" {
            if let newStart = item.newStart, let newEnd = item.newEnd {
                return "Time: \(customerFacingInterval(start: newStart, end: newEnd))"
            }
        } else if item.status == "would delete" {
            if let oldStart = item.oldStart, let oldEnd = item.oldEnd {
                return "Time: \(customerFacingInterval(start: oldStart, end: oldEnd))"
            }
        }
        return nil
    }

    private var statusIcon: String {
        switch item.status {
        case "would create": return "plus.circle.fill"
        case "would update": return "arrow.triangle.2.circlepath.circle.fill"
        case "would delete": return "minus.circle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "would create": return .green
        case "would update": return .blue
        case "would delete": return .red
        default: return .secondary
        }
    }
}
