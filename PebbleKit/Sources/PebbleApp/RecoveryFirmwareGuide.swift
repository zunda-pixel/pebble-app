import SwiftUI

/// What to do with a watch that came up in its recovery firmware.
///
/// The watch reaches this state after a factory reset or a firmware update that
/// did not finish, and in it the only thing it accepts is a firmware install —
/// so the screen is a set of steps ending in one.
struct RecoveryFirmwareGuide<FirmwareDestination: View>: View {
    var watchName: String
    var isConnected: Bool
    @ViewBuilder var firmwareDestination: () -> FirmwareDestination

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(watchName) needs firmware")
                            .font(.headline)
                        Text("It started its recovery firmware, which can do one thing: take a new copy of PebbleOS. Apps, watchfaces, and notifications come back once that is installed.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lifepreserver.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            }

            // Not "Steps": that key is the health screen's step count.
            Section("What to Do") {
                GuideStep(number: 1, text: "Put the watch on its charger and keep it next to this device.")
                GuideStep(number: 2, text: "Open Firmware below and check for updates.")
                GuideStep(number: 3, text: "Download the published PebbleOS, then install it.")
                GuideStep(number: 4, text: "Leave both alone until the watch restarts by itself.")
            }

            Section {
                NavigationLink {
                    firmwareDestination()
                } label: {
                    Label("Install Firmware", systemImage: "arrow.down.app")
                }
            } footer: {
                if isConnected {
                    Text("A watch in recovery firmware disconnects often. The install picks itself up again on the next connection, so a drop part-way through is not a lost update.")
                } else {
                    Text("The download only needs the network. It installs as soon as this watch connects.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Firmware Required"))
    }
}

private struct GuideStep: View {
    var number: Int
    var text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
    }
}

#Preview("Connected") {
    NavigationStack {
        RecoveryFirmwareGuide(watchName: "Pebble 5209", isConnected: true) {
            EmptyView()
        }
    }
}

#Preview("Away") {
    NavigationStack {
        RecoveryFirmwareGuide(watchName: "Pebble 5209", isConnected: false) {
            EmptyView()
        }
    }
}
