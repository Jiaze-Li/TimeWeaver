import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderPaneView()
            QuickActionsPaneView()

            HSplitView {
                SidebarPaneView()
                    .frame(minWidth: 150, idealWidth: 205, maxWidth: 320, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                ScrollView {
                    detailColumn
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(minWidth: 640, minHeight: 620)
        .overlay(syncLoadingOverlay)
        .sheet(isPresented: $model.showIgnoredReviews) {
            IgnoredChangesSheet().environmentObject(model)
        }
        .sheet(item: $model.ui.pendingImageImportReview) { review in
            ImageImportReviewSheet(review: review)
                .environmentObject(model)
        }
        .alert(item: $model.ui.pendingSyncConfirmation) { confirmation in
            Alert(
                title: Text("Confirm Sync"),
                message: Text(confirmation.message),
                primaryButton: .default(Text("Continue")) {
                    model.confirmPendingSync()
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    model.cancelPendingSync()
                }
            )
        }
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorPaneView()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var syncLoadingOverlay: some View {
        if model.ui.isBusy && !model.isCheckingAutomatically {
            ZStack {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(model.ui.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 8)
            }
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appDisplayName)
                .font(.headline)
            Text(model.ui.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("Show Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)

            Button("Preview Now") {
                model.previewAll()
            }
            .buttonStyle(.plain)
            .disabled(model.ui.isBusy)

            Button("Sync Now") {
                model.syncAll()
            }
            .buttonStyle(.plain)
            .disabled(model.ui.isBusy)

            Button("Open Calendar") {
                model.openCalendarApp()
            }
            .buttonStyle(.plain)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }
}
