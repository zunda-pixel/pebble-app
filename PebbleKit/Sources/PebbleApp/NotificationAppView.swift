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
            supportsVibePatterns: model.connections.contains { $0.device.supportsCustomVibePatterns }
        )
    }
}

/// One phone app's notifications, as the watch shows them.
struct NotificationAppContent: View {
    var app: NotificationSourceApp
    var setMute: (NotificationAppMuteState) -> Void
    var setIcon: (PebbleTimelineIcon?) -> Void
    var setColours: (_ background: PebbleColor?, _ foreground: PebbleColor?) -> Void
    var setVibePattern: (NotificationVibePattern?) -> Void
    /// Older firmware plays its own buzz and cannot be told another.
    var supportsVibePatterns: Bool = true

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
                ColourGrid(
                    selection: current.backgroundColor,
                    onChoose: { colour in setColours(colour, current.foregroundColor) }
                )
            } header: {
                Text("Background")
            } footer: {
                Text("The watch's screen has four levels of each colour, and these are all of them. Choosing none leaves the colour the watch already uses for this app.")
            }

            Section {
                ColourGrid(
                    selection: current.foregroundColor,
                    onChoose: { colour in setColours(current.backgroundColor, colour) }
                )
            } header: {
                Text("Text")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: current.displayName))
    }
}


/// Every colour the watch has, as swatches. There are sixty-four of them and no
/// names worth giving them, so they are shown rather than listed.
struct ColourGrid: View {
    var selection: PebbleColor?
    var onChoose: (PebbleColor?) -> Void

    private let columns = Array(repeating: GridItem(.adaptive(minimum: 28), spacing: 6), count: 1)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            swatch(for: nil)
            ForEach(PebbleColor.all, id: \.self) { colour in
                swatch(for: colour)
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(for colour: PebbleColor?) -> some View {
        Button {
            onChoose(colour)
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(fill(for: colour))
                .frame(height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.tint, lineWidth: selection == colour ? 3 : 0)
                }
                .overlay {
                    if colour == nil {
                        Image(systemName: "slash.circle").foregroundStyle(.secondary)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(colour.map { colour in
            Text("Red \(colour.red), green \(colour.green), blue \(colour.blue)")
        } ?? Text("Chosen by the Watch"))
    }

    private func fill(for colour: PebbleColor?) -> Color {
        guard let colour else { return Color(white: 0.5, opacity: 0.15) }
        let (red, green, blue) = colour.components
        return Color(red: red, green: green, blue: blue)
    }
}

#Preview("App") {
    NavigationStack {
        NotificationAppContent(
            app: PreviewSamples.notificationApps[1],
            setMute: { _ in },
            setIcon: { _ in },
            setColours: { _, _ in },
            setVibePattern: { _ in }
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
            supportsVibePatterns: false
        )
    }
}

#Preview("Colours") {
    Form {
        ColourGrid(selection: PebbleColor(red: 3, green: 0, blue: 0)) { _ in }
    }
    .formStyle(.grouped)
}
