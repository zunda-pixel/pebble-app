import SwiftUI
import API

struct LanguageView: View {
    var model: AppModel
    var watchID: String
    @State private var isChoosingFile = false

    private var connection: WatchConnection? {
        model.connections.first { $0.device.id == watchID }
    }

    private var isConnected: Bool {
        connection?.isConnected == true
    }

    // An empty locale is the firmware's built-in English rather than a missing
    // answer.
    private var installedLocale: String? {
        guard let locale = connection?.device.languageLocale, !locale.isEmpty else { return nil }
        return locale
    }

    private var packs: [PebbleLanguagePack] {
        model.languagePacks(deviceID: watchID)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("On the Watch") {
                    if let installedLocale {
                        Text(verbatim: languageName(for: installedLocale))
                    } else if isConnected {
                        Text("English (built in)")
                    } else {
                        Text("Unknown")
                    }
                }
                if let version = connection?.device.languageVersion, version > 0 {
                    LabeledContent("Pack Version", value: version, format: .number)
                }
                if let message = model.languageStatusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let progress = model.installationProgress, progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.bytesSent), total: Double(progress.totalBytes))
                }
            }

            Section {
                ForEach(packs) { pack in
                    Button {
                        Task { await model.installLanguagePack(pack, deviceID: watchID) }
                    } label: {
                        LabeledContent {
                            if pack.locale == installedLocale {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Installed")
                            }
                        } label: {
                            Text(verbatim: pack.localName)
                            Text(verbatim: pack.locale)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isConnected || model.isInstallingLanguagePack)
                }
            } header: {
                Text("Languages")
            } footer: {
                if packs.isEmpty {
                    Text("Connect the watch once so its board is known, and the languages built for it appear here.")
                } else {
                    Text("Installing a language replaces the one on the watch. The watch switches over by itself and says so on its own screen. English needs no pack: it is part of the firmware.")
                }
            }

            Section {
                Button("Install from a File…", systemImage: "folder") {
                    isChoosingFile = true
                }
                .disabled(!isConnected || model.isInstallingLanguagePack)
            } footer: {
                Text("A PBL pack built for this watch's board. A pack built for another board installs but shows the wrong glyphs.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Language")
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.pebbleLanguagePack]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.installLanguagePack(from: url, deviceID: watchID) }
        }
    }

    // A watch may be running a pack this app does not offer, so the system's own
    // name stands in where the list has none.
    private func languageName(for locale: String) -> String {
        if let pack = packs.first(where: { $0.locale == locale }) {
            return pack.localName
        }
        let identifier = locale.replacingOccurrences(of: "_", with: "-")
        return Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? locale
    }
}
