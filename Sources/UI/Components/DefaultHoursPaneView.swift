import SwiftUI
import AppKit

struct DefaultHoursPaneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneHeader(
                title: "Default Work Hours",
                subtitle: "Used only when a sheet shows dates without specific times. If the sheet already includes exact times, those times win automatically."
            )

            WorkdayHoursEditor(start: deferredBinding(model: model, \.workdayStart), end: deferredBinding(model: model, \.workdayEnd))
                .onChange(of: model.ui.workdayStart) { _ in
                    model.workdayChanged()
                }
                .onChange(of: model.ui.workdayEnd) { _ in
                    model.workdayChanged()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            clearInputFocus()
        }
    }
}
