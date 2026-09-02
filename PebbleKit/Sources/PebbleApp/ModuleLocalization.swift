import SwiftUI

// Every SwiftUI initializer that takes a `LocalizedStringKey` looks it up in
// `Bundle.main` — the app — however the view was compiled, and the screens live
// in this package, whose strings ship in its own bundle. Left alone, a Japanese
// iPhone shows a finished catalogue as English keys.
//
// The alternative was passing `bundle: .module` at each of the 271 call sites,
// which means giving up `Section("Watch")` and `Button("Connect", systemImage:)`
// for their closure forms and remembering it forever after. These declare the
// same signatures inside this module instead: a call in this module resolves to
// the one here, which fills the bundle in and forwards.
//
// A SwiftUI API used with a literal and *not* listed here silently falls back to
// the main bundle, so a screen whose text comes out English is missing a shim.

extension Bundle {
    /// This module's own bundle, named so a test can ask for it: `.module` inside
    /// a test file resolves against the test target instead.
    static let pebbleApp = Bundle.module
}

extension Text {
    init(_ key: LocalizedStringKey) {
        self.init(key, bundle: .pebbleApp)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ titleKey: LocalizedStringKey, systemImage name: String) {
        self.init {
            Text(titleKey)
        } icon: {
            Image(systemName: name)
        }
    }
}

extension Button where Label == Text {
    init(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(action: action) {
            Text(titleKey)
        }
    }

    init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) {
            Text(titleKey)
        }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ titleKey: LocalizedStringKey, systemImage name: String, action: @escaping () -> Void) {
        self.init(action: action) {
            SwiftUI.Label(titleKey, systemImage: name)
        }
    }

    init(
        _ titleKey: LocalizedStringKey,
        systemImage name: String,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) {
        self.init(role: role, action: action) {
            SwiftUI.Label(titleKey, systemImage: name)
        }
    }
}

extension Section where Parent == Text, Footer == EmptyView {
    init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content) {
            Text(titleKey)
        }
    }
}

extension Toggle where Label == Text {
    init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) {
            Text(titleKey)
        }
    }
}

extension LabeledContent where Label == Text, Content: View {
    init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content) {
            Text(titleKey)
        }
    }
}

extension LabeledContent where Label == Text, Content == Text {
    init(_ titleKey: LocalizedStringKey, value: some StringProtocol) {
        self.init {
            Text(value)
        } label: {
            Text(titleKey)
        }
    }

    init<F: FormatStyle>(
        _ titleKey: LocalizedStringKey,
        value: F.FormatInput,
        format: F
    ) where F.FormatInput: Equatable, F.FormatOutput == String {
        self.init {
            Text(value, format: format)
        } label: {
            Text(titleKey)
        }
    }
}

extension Picker where Label == Text {
    init(
        _ titleKey: LocalizedStringKey,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) {
        self.init(selection: selection, content: content) {
            Text(titleKey)
        }
    }
}

extension DatePicker where Label == Text {
    init(
        _ titleKey: LocalizedStringKey,
        selection: Binding<Date>,
        displayedComponents: DatePickerComponents = [.hourAndMinute, .date]
    ) {
        self.init(selection: selection, displayedComponents: displayedComponents) {
            Text(titleKey)
        }
    }
}

extension DisclosureGroup where Label == Text {
    init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content) {
            Text(titleKey)
        }
    }
}

extension TextField where Label == Text {
    init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.init(text: text) {
            Text(titleKey)
        }
    }
}

extension Stepper where Label == Text {
    init<Value: Strideable>(
        _ titleKey: LocalizedStringKey,
        value: Binding<Value>,
        in bounds: ClosedRange<Value>,
        step: Value.Stride = 1
    ) {
        self.init(value: value, in: bounds, step: step) {
            Text(titleKey)
        }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ titleKey: LocalizedStringKey, systemImage name: String, description: Text? = nil) {
        self.init {
            SwiftUI.Label(titleKey, systemImage: name)
        } description: {
            description
        }
    }
}

// A modifier cannot be shimmed the same way: `navigationTitle`, the two
// accessibility ones and `confirmationDialog` differ from ours only in their
// return type, and the compiler calls that ambiguous. Those call sites pass
// `Text("…")` themselves, which lands back on the initializer above.
