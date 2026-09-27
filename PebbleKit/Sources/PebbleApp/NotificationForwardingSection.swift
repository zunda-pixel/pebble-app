import SwiftUI

/// Whether iOS forwards this watch's notifications to it, and the way to
/// change that. iOS asks the reader and keeps the choice; this only shows it.
struct NotificationForwardingSection<ReplyTemplatesDestination: View>: View {
    /// Nil until iOS has answered.
    var forwarding: NotificationForwarding?
    var allow: () -> Void
    var openSettings: () -> Void
    @ViewBuilder var replyTemplatesDestination: () -> ReplyTemplatesDestination

    var body: some View {
        Section {
            LabeledContent("Status") {
                switch forwarding {
                case .on: Text("On")
                case .someApps: Text("Some Apps")
                case .off: Text("Off")
                case .notSetUp: Text("Not Set Up")
                case .unsupportedAccessory: Text("Not Supported")
                case .unavailable: Text("Unavailable")
                case nil: ProgressView()
                }
            }
            switch forwarding {
            case .off:
                Button("Allow Forwarding", systemImage: "bell.badge", action: allow)
            case .on, .someApps:
                Button("Choose Apps", systemImage: "gear", action: openSettings)
            case .notSetUp, .unsupportedAccessory, .unavailable, nil:
                EmptyView()
            }
            switch forwarding {
            case .on, .someApps, .off:
                NavigationLink(destination: replyTemplatesDestination) {
                    Label("Reply Templates", systemImage: "text.bubble")
                }
            case .notSetUp, .unsupportedAccessory, .unavailable, nil:
                EmptyView()
            }
        } header: {
            Text("iPhone Notifications")
        } footer: {
            switch forwarding {
            case .notSetUp:
                Text("This watch was added before the app paired watches through iOS. Forget it and add it again to forward notifications to it.")
            case .unsupportedAccessory:
                Text("iOS does not take this watch as one it can forward notifications to.")
            case .unavailable:
                Text("iOS does not forward notifications to this watch. It needs firmware that supports it, and outside development iOS offers this only in the EU.")
            default:
                Text("iOS sends the watch its notifications encrypted, and the watch shows them in place of the ones it reads over Bluetooth itself. When you reply from the watch, it offers your reply templates.")
            }
        }
    }
}

#Preview("Off") {
    NavigationStack {
        Form {
            NotificationForwardingSection(forwarding: .off, allow: {}, openSettings: {}) {
                ReplyTemplatesContent(
                    templates: PreviewSamples.replyTemplates,
                    add: { _ in },
                    update: { _ in },
                    remove: { _ in },
                    move: { _, _ in }
                )
            }
        }
    }
}

#Preview("On") {
    NavigationStack {
        Form {
            NotificationForwardingSection(forwarding: .on, allow: {}, openSettings: {}) {
                ReplyTemplatesContent(
                    templates: PreviewSamples.replyTemplates,
                    add: { _ in },
                    update: { _ in },
                    remove: { _ in },
                    move: { _, _ in }
                )
            }
        }
    }
}

#Preview("Added before accessory setup") {
    NavigationStack {
        Form {
            NotificationForwardingSection(forwarding: .notSetUp, allow: {}, openSettings: {}) {
                EmptyView()
            }
        }
    }
}

#Preview("Not supported") {
    NavigationStack {
        Form {
            NotificationForwardingSection(forwarding: .unsupportedAccessory, allow: {}, openSettings: {}) {
                EmptyView()
            }
        }
    }
}

#Preview("Unavailable") {
    NavigationStack {
        Form {
            NotificationForwardingSection(forwarding: .unavailable, allow: {}, openSettings: {}) {
                EmptyView()
            }
        }
    }
}

#Preview("Asking iOS") {
    NavigationStack {
        Form {
            NotificationForwardingSection(forwarding: nil, allow: {}, openSettings: {}) {
                EmptyView()
            }
        }
    }
}
