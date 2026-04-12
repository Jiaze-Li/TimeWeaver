import SwiftUI
import AppKit

@MainActor
func deferredBinding<Value: Equatable>(model: AppModel, _ keyPath: WritableKeyPath<UIState, Value>) -> Binding<Value> {
    Binding(
        get: { model.ui[keyPath: keyPath] },
        set: { newValue in
            guard model.ui[keyPath: keyPath] != newValue else { return }
            DispatchQueue.main.async {
                model.ui[keyPath: keyPath] = newValue
            }
        }
    )
}

func clearInputFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    NSApp.mainWindow?.makeFirstResponder(nil)
}
