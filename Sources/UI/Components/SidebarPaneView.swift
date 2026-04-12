import SwiftUI
import AppKit

struct SidebarPaneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VSplitView {
            SourcesPaneView()
                .frame(minHeight: 120, idealHeight: 220, maxHeight: .infinity, alignment: .topLeading)
            ActivityPaneView()
                .frame(minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
