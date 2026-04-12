import SwiftUI
import AppKit

struct QuickActionsPaneView: View {
    @EnvironmentObject private var model: AppModel
    @State private var quickActionsWidth: CGFloat = 0

    private enum QuickActionLayoutMode {
        case singleRow
        case pairedRows
        case singleColumn
    }

    private var manageSourcesMaxWidth: CGFloat {
        quickActionsWidth > 0 ? (quickActionsWidth - 12) * 3 / 8 : .infinity
    }

    private var runSyncMaxWidth: CGFloat {
        quickActionsWidth > 0 ? (quickActionsWidth - 12) * 5 / 8 : .infinity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Actions")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    manageSourcesPane(layout: .singleRow)
                        .frame(maxWidth: manageSourcesMaxWidth, alignment: .topLeading)
                    runSyncPane(layout: .singleRow)
                        .frame(maxWidth: runSyncMaxWidth, alignment: .topLeading)
                }

                HStack(alignment: .top, spacing: 12) {
                    manageSourcesPane(layout: .pairedRows)
                        .frame(maxWidth: manageSourcesMaxWidth, alignment: .topLeading)
                    runSyncPane(layout: .pairedRows)
                        .frame(maxWidth: runSyncMaxWidth, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 10) {
                    manageSourcesPane(layout: .singleColumn)
                    Divider()
                    runSyncPane(layout: .singleColumn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { quickActionsWidth = geo.size.width }
                .onChange(of: geo.size.width) { quickActionsWidth = $0 }
        })
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    @ViewBuilder
    private func manageSourcesPane(layout: QuickActionLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manage Sources")
                .font(.subheadline.weight(.semibold))
            switch layout {
            case .singleRow:
                HStack(spacing: 8) {
                    newSourceButton
                    saveSourceButton
                    removeSourceButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .pairedRows:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        newSourceButton
                        saveSourceButton
                    }
                    HStack(spacing: 8) {
                        removeSourceButton
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .singleColumn:
                VStack(alignment: .leading, spacing: 8) {
                    newSourceButton
                    saveSourceButton
                    removeSourceButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func runSyncPane(layout: QuickActionLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run Sync")
                .font(.subheadline.weight(.semibold))
            switch layout {
            case .singleRow:
                HStack(spacing: 8) {
                    previewButton
                    syncButton
                    approveAIButton
                    openCalendarButton
                    undoImportButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .pairedRows:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        previewButton
                        syncButton
                    }
                    HStack(spacing: 8) {
                        approveAIButton
                        openCalendarButton
                        undoImportButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .singleColumn:
                VStack(alignment: .leading, spacing: 8) {
                    previewButton
                    syncButton
                    approveAIButton
                    openCalendarButton
                    undoImportButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.ui.pendingAIReviews.isEmpty {
                Text("\(model.ui.pendingAIReviews.count) source(s) need AI approval before low-confidence sync can run.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }

    private var newSourceButton: some View {
        Button {
            clearInputFocus()
            model.newSource()
        } label: {
            Label("New", systemImage: "plus")
        }
        .buttonStyle(.bordered)
    }

    private var saveSourceButton: some View {
        Button {
            clearInputFocus()
            model.saveCurrentSource()
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
    }

    private var removeSourceButton: some View {
        Button(role: .destructive) {
            clearInputFocus()
            model.removeSelectedSource()
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(model.ui.selectedSourceID == nil)
    }

    private var previewButton: some View {
        Button {
            clearInputFocus()
            model.previewAll()
        } label: {
            Label("Preview", systemImage: "eye")
        }
        .buttonStyle(.bordered)
        .disabled(model.ui.isBusy)
    }

    private var syncButton: some View {
        Button {
            clearInputFocus()
            model.syncAll()
        } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.ui.isBusy)
    }

    private var openCalendarButton: some View {
        Button {
            clearInputFocus()
            model.openCalendarApp()
        } label: {
            Label("Calendar", systemImage: "calendar")
        }
        .buttonStyle(.bordered)
    }

    private var approveAIButton: some View {
        Button {
            clearInputFocus()
            model.approvePendingAIReviews()
        } label: {
            Label("Approve AI", systemImage: "checkmark.shield")
        }
        .buttonStyle(.bordered)
        .disabled(model.ui.pendingAIReviews.isEmpty || model.ui.isBusy)
    }

    private var undoImportButton: some View {
        Button(role: .destructive) {
            clearInputFocus()
            model.undoLastImageImport()
        } label: {
            Label("Undo Import", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.bordered)
        .disabled(model.ui.lastImageImportUndo == nil || model.ui.isBusy)
    }
}
