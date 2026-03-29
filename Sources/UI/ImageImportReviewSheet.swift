import SwiftUI

// Receives a stable local copy of entries via @State — avoids force-unwrap
// crashes when the optional pendingImageImportReview becomes nil during sheet dismissal.
struct ImageImportReviewSheet: View {
    @EnvironmentObject var model: AppModel
    let plan: ImageImportPlan
    @State var entries: [ImageImportEventEntry]

    init(review: ImageImportReview) {
        self.plan = review.plan
        self._entries = State(initialValue: review.entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($entries) { $entry in
                        EventEntryRow(
                            entry: $entry,
                            tzID: model.ui.schedulingTimeZoneIdentifier
                        )
                        Divider()
                            .padding(.leading, 38)
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 340)
            Divider()
            footerView
        }
        .frame(minWidth: 500)
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review Schedule Items")
                .font(.headline)
            HStack(spacing: 6) {
                Text("\(plan.matchedCount) \(plan.matchedCount == 1 ? "item" : "items")")
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("Calendar: \(plan.source.calendar)")
                    .foregroundStyle(.secondary)
                if plan.reviewRequired {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Label("AI interpreted", systemImage: "sparkles")
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
            if plan.reviewRequired {
                Label("Double-check dates before importing.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Button("Cancel") {
                model.cancelImageImportReview()
            }
            .keyboardShortcut(.cancelAction)
            Button("Add to Calendar") {
                model.confirmImageImportReview(entries: entries)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct EventEntryRow: View {
    @Binding var entry: ImageImportEventEntry
    let tzID: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
                .font(.system(size: 12, weight: .semibold))

            TextField("Event title", text: $entry.title)
                .textFieldStyle(.plain)
                .frame(minWidth: 120, idealWidth: 200, maxWidth: 220)

            Spacer(minLength: 8)

            DatePicker("", selection: $entry.start, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.field)
            Text("–")
                .font(.caption)
                .foregroundStyle(.secondary)
            DatePicker("", selection: $entry.end, displayedComponents: [.hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.field)
        }
        .environment(\.timeZone, TimeZone(identifier: tzID) ?? .current)
        .environment(\.locale, Locale(identifier: "sv_SE"))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusIcon: String {
        switch entry.status {
        case "would create": return "plus.circle.fill"
        case "would update": return "arrow.triangle.2.circlepath.circle.fill"
        case "would delete": return "minus.circle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case "would create": return .green
        case "would update": return .blue
        case "would delete": return .red
        default: return .secondary
        }
    }

}
