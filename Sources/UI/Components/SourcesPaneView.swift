import SwiftUI

struct SourcesPaneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.ui.sources) { item in
                        Button {
                            clearInputFocus()
                            model.selectSource(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    sourceStatusIcon(for: item)
                                    Text(item.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    if !item.enabled {
                                        Text("Off")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule()
                                                    .fill(Color.secondary.opacity(0.12))
                                            )
                                    }
                                }
                                Text(sourceStatusSummary(for: item))
                                    .font(.caption)
                                    .foregroundStyle(sourceStatusColor(for: item))
                                    .lineLimit(1)
                                Text("\(item.bookingID) -> \(item.calendar)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(model.ui.selectedSourceID == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(sourceStatusHelp(for: item))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func sourceStatusIcon(for item: SourceItem) -> some View {
        switch model.runtimeStatus(for: item) {
        case .idle:
            Image(systemName: item.enabled ? "circle" : "pause.circle")
                .foregroundStyle(item.enabled ? Color.secondary : Color.secondary.opacity(0.8))
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .review:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failure:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func sourceStatusSummary(for item: SourceItem) -> String {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return item.enabled ? "Ready to read" : "Saved but skipped"
        case .loading:
            return "Reading sheet..."
        case .success(let matchCount):
            let noun = matchCount == 1 ? "match" : "matches"
            return "Read OK · \(matchCount) \(noun)"
        case .review(let matchCount):
            let noun = matchCount == 1 ? "match" : "matches"
            return "Review needed · \(matchCount) \(noun)"
        case .failure:
            return "Read failed"
        }
    }

    private func sourceStatusHelp(for item: SourceItem) -> String {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return item.enabled ? "This source is enabled and ready for preview or sync." : "This source is saved but currently skipped during preview and sync."
        case .loading:
            return "The app is downloading or parsing this source now."
        case .success(let matchCount):
            let noun = matchCount == 1 ? "reservation" : "reservations"
            return "The last read succeeded and found \(matchCount) matching \(noun)."
        case .review(let matchCount):
            let noun = matchCount == 1 ? "reservation" : "reservations"
            return "The source was parsed, but the AI confidence is too low for unattended sync. Preview and approve this layout before syncing. Current preview found \(matchCount) matching \(noun)."
        case .failure(let message):
            return message
        }
    }

    private func sourceStatusColor(for item: SourceItem) -> Color {
        switch model.runtimeStatus(for: item) {
        case .idle:
            return .secondary
        case .loading:
            return .secondary
        case .success:
            return .green
        case .review:
            return .orange
        case .failure:
            return .red
        }
    }
}
