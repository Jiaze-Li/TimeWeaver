import SwiftUI

struct EditorPaneView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceDetailsPaneView()
            AIParsingPaneView()
            DefaultHoursPaneView()
            AutomationPaneView()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
