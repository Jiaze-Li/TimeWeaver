import SwiftUI

struct IgnoredChangesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ignored Changes").font(.title3).bold()
                    Text("Review Again checks the latest calendar. Unignore allows the next automatic check to notify you again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()
            if model.ignoredReviews.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.title2)
                    Text("No ignored changes")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.ignoredReviews) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(record.items.first?.sourceName ?? "Ignored booking").font(.headline)
                                    Text(record.ignoredAt, style: .date)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Review Again") {
                                        model.revisitIgnoredReview(record)
                                    }
                                    Button("Unignore") {
                                        model.unignoreAutoReview(record)
                                    }
                                    .disabled(model.ui.isBusy || model.ui.pendingAutoReview != nil)
                                }
                                ForEach(record.items) { item in
                                    AutoReviewItemRow(item: item)
                                }
                            }
                            .padding(12)
                            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 380)
    }
}
