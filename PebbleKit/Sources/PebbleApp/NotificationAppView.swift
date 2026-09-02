import PebbleProtocol
import SwiftUI

struct NotificationAppView: View {
    var model: AppModel
    var app: NotificationSourceApp

    private var current: NotificationSourceApp {
        model.notificationSourceApps.first { $0.bundleID == app.bundleID } ?? app
    }

    var body: some View {
        NotificationAppContent(
            app: current,
            setMute: { state in
                Task { await model.setNotificationSourceAppMute(bundleID: app.bundleID, muteState: state) }
            },
            setIcon: { icon in
                Task { await model.setNotificationSourceAppIcon(bundleID: app.bundleID, icon: icon) }
            },
            setColours: { background, foreground in
                Task {
                    await model.setNotificationSourceAppColors(
                        bundleID: app.bundleID,
                        background: background,
                        foreground: foreground
                    )
                }
            },
            setVibePattern: { pattern in
                Task {
                    await model.setNotificationSourceAppVibePattern(
                        bundleID: app.bundleID,
                        pattern: pattern
                    )
                }
            },
            supportsVibePatterns: model.connections.contains { $0.device.supportsCustomVibePatterns },
            rulesDestination: { NotificationRulesView(model: model, app: app) }
        )
    }
}

/// One phone app's notifications, as the watch shows them.
struct NotificationAppContent<RulesDestination: View>: View {
    var app: NotificationSourceApp
    var setMute: (NotificationAppMuteState) -> Void
    var setIcon: (PebbleTimelineIcon?) -> Void
    var setColours: (_ background: PebbleColor?, _ foreground: PebbleColor?) -> Void
    var setVibePattern: (NotificationVibePattern?) -> Void
    /// Older firmware plays its own buzz and cannot be told another.
    var supportsVibePatterns: Bool = true
    @ViewBuilder var rulesDestination: () -> RulesDestination

    private var current: NotificationSourceApp { app }

    var body: some View {
        Form {
            Section {
                Picker("Mute", selection: Binding(
                    get: { current.muteState },
                    set: { state in setMute(state) }
                )) {
                    ForEach(NotificationAppMuteState.allCases, id: \.self) { state in
                        Text(state.title).tag(state)
                    }
                }
                NavigationLink {
                    rulesDestination()
                } label: {
                    LabeledContent("Rules") {
                        Text(current.filterRules.count, format: .number)
                    }
                }
            } header: {
                Text("Notifications")
            }

            Section {
                Picker("Buzz", selection: Binding(
                    get: { current.vibePattern },
                    set: { pattern in setVibePattern(pattern) }
                )) {
                    Text("Chosen by the Watch").tag(NotificationVibePattern?.none)
                    ForEach(NotificationVibePattern.allCases, id: \.self) { pattern in
                        Text(pattern.title).tag(NotificationVibePattern?.some(pattern))
                    }
                }
                .disabled(!supportsVibePatterns)
            } header: {
                Text("Vibration")
            } footer: {
                if supportsVibePatterns {
                    Text("The watch buzzes the way its own settings say unless one is chosen here.")
                } else {
                    Text("This watch's firmware plays the buzz its own settings choose and cannot be told another.")
                }
            }

            Section {
                Picker("Icon", selection: Binding(
                    get: { current.icon },
                    set: { icon in setIcon(icon) }
                )) {
                    Text("Chosen by the Watch").tag(PebbleTimelineIcon?.none)
                    ForEach(PebbleTimelineIcon.choosable, id: \.self) { icon in
                        Text(icon.title).tag(PebbleTimelineIcon?.some(icon))
                    }
                }
            } header: {
                Text("Icon")
            } footer: {
                Text("The watch has a logo of its own for the apps it knows. Choosing one here is for the ones it does not.")
            }

            Section {
                WatchColorPicker(
                    label: Text("Background"),
                    selection: current.backgroundColor,
                    onChoose: { colour in setColours(colour, current.foregroundColor) }
                )
                WatchColorPicker(
                    label: Text("Text"),
                    selection: current.foregroundColor,
                    onChoose: { colour in setColours(current.backgroundColor, colour) }
                )
                if current.backgroundColor != nil || current.foregroundColor != nil {
                    Button("Chosen by the Watch") { setColours(nil, nil) }
                }
            } header: {
                Text("Colours")
            } footer: {
                Text("The watch's screen has four levels of each colour, so a colour picked here becomes the nearest one it can show. Until one is picked, the watch uses the colours it already has for this app.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: current.displayName))
    }
}

/// A colour for the watch, picked the way any other colour is picked on the
/// phone.
///
/// The phone offers millions and the watch has sixty-four, so what comes back
/// from the picker is rounded to the nearest the screen can show — and the
/// picker is shown that rounded colour, not the one picked, so the swatch is
/// the colour the watch will use.
struct WatchColorPicker: View {
    var label: Text
    var selection: PebbleColor?
    var onChoose: (PebbleColor) -> Void

    @Environment(\.self) private var environment

    var body: some View {
        ColorPicker(
            selection: Binding(
                get: { Color(selection ?? .white) },
                set: { colour in
                    // The picker reports every step of a drag, and sixty-four
                    // colours means most of those steps round to the one
                    // already chosen. Only a change is worth writing down.
                    let rounded = PebbleColor(nearest: colour, in: environment)
                    guard rounded != selection else { return }
                    onChoose(rounded)
                }
            ),
            supportsOpacity: false
        ) {
            label
        }
    }
}

#Preview("App") {
    NavigationStack {
        NotificationAppContent(
            app: PreviewSamples.notificationApps[1],
            setMute: { _ in },
            setIcon: { _ in },
            setColours: { _, _ in },
            setVibePattern: { _ in },
            rulesDestination: { EmptyView() }
        )
    }
}

#Preview("App on older firmware") {
    NavigationStack {
        NotificationAppContent(
            app: PreviewSamples.notificationApps[1],
            setMute: { _ in },
            setIcon: { _ in },
            setColours: { _, _ in },
            setVibePattern: { _ in },
            supportsVibePatterns: false,
            rulesDestination: { EmptyView() }
        )
    }
}

#Preview("Colours") {
    Form {
        WatchColorPicker(
            label: Text("Background"),
            selection: PebbleColor(red: 3, green: 0, blue: 0),
            onChoose: { _ in }
        )
    }
    .formStyle(.grouped)
}
