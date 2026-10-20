import SwiftUI

final class LocalBox<T>: ObservableObject { @Published var value: T; init(_ v: T) { value = v } }

/// View-local state built on @StateObject. Used instead of @State because the macOS 27 SDK declares
/// @State as a macro whose compiler plugin ships only with full Xcode; this keeps the project
/// buildable with the Command Line Tools alone (and it also builds under Xcode).
@propertyWrapper
struct Local<T>: DynamicProperty {
    @StateObject private var box: LocalBox<T>
    init(wrappedValue: T) { _box = StateObject(wrappedValue: LocalBox(wrappedValue)) }
    var wrappedValue: T { get { box.value } nonmutating set { box.value = newValue } }
    var projectedValue: Binding<T> { Binding(get: { box.value }, set: { box.value = $0 }) }
}

@MainActor func openSettingsWindow() {
    NSApp.activate(ignoringOtherApps: true)
    // "showSettingsWindow:" is the macOS 14+ name; macOS 13 used "showPreferencesWindow:".
    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
