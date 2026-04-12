import SwiftUI
import AppKit

struct HeaderPaneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appDisplayName)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(appTagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    headerStatusPane
                        .frame(maxWidth: 360, alignment: .leading)
                }

                Spacer(minLength: 12)

                summaryPane
                    .frame(idealWidth: 240, maxWidth: 300, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appDisplayName)
                        .font(.title2.weight(.semibold))
                    Text(appTagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                headerStatusPane
                summaryPane
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var summaryPane: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                SummaryCard(title: "Sources", value: "\(model.ui.sources.count)", symbol: "square.stack.3d.up")
                SummaryCard(title: "Active", value: "\(model.ui.sources.filter(\.enabled).count)", symbol: "checkmark.circle")
                SummaryCard(title: "Calendars", value: "\(model.ui.calendars.count)", symbol: "calendar")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                SummaryCard(title: "Sources", value: "\(model.ui.sources.count)", symbol: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
                SummaryCard(title: "Active", value: "\(model.ui.sources.filter(\.enabled).count)", symbol: "checkmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                SummaryCard(title: "Calendars", value: "\(model.ui.calendars.count)", symbol: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headerStatusPane: some View {
        HStack(alignment: .center, spacing: 8) {
            if model.ui.isBusy || model.ui.isCalendarLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.ui.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}
