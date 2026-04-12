import SwiftUI
import AppKit

struct AutomationPaneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(
                title: "Automation",
                subtitle: "Polling only runs while the app stays open. Closed apps do not sync."
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    automationToggles
                    automationIntervalField
                }

                VStack(alignment: .leading, spacing: 10) {
                    automationToggles
                    automationIntervalField
                }
            }
            Text("The app can add, update, and remove previously synced events when the source changes. You can confirm every sync, or only ask before deletions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }

    private var automationToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Only future reservations", isOn: deferredBinding(model: model, \.upcomingOnly))
                .onChange(of: model.ui.upcomingOnly) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Auto sync while the app is open", isOn: deferredBinding(model: model, \.autoSyncEnabled))
                .onChange(of: model.ui.autoSyncEnabled) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Show confirmation before sync", isOn: deferredBinding(model: model, \.confirmBeforeSync))
                .onChange(of: model.ui.confirmBeforeSync) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Ask before deleting removed events", isOn: deferredBinding(model: model, \.confirmBeforeDeletion))
                .onChange(of: model.ui.confirmBeforeDeletion) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
            Toggle("Keep running in menu bar", isOn: deferredBinding(model: model, \.menuBarModeEnabled))
                .onChange(of: model.ui.menuBarModeEnabled) { _ in
                    model.automationChanged()
                }
                .controlSize(.small)
        }
    }

    private var automationIntervalField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title: "Interval (minutes)")
            TextField("15", text: deferredBinding(model: model, \.autoSyncMinutes))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 92, idealWidth: 110, maxWidth: 140, alignment: .leading)
                .controlSize(.small)
                .onSubmit {
                    model.automationChanged()
                }
                .onChange(of: model.ui.autoSyncMinutes) { _ in
                    model.automationChanged()
                }
        }
    }
}
