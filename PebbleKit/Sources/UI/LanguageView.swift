import SwiftUI
import API

struct LanguageView: View {
    var model: AppModel
    var watchID: String

    private var connection: WatchConnection? {
        model.connections.first { $0.device.id == watchID }
    }

    var body: some View {
        LanguageContent(
            packs: model.languagePacks(deviceID: watchID),
            installedLocale: connection?.device.languageLocale,
            installedVersion: connection?.device.languageVersion,
            isConnected: connection?.isConnected == true,
            isInstalling: model.isInstallingLanguagePack,
            progress: model.installationProgress,
            statusMessage: model.languageStatusMessage,
            install: { pack in
                Task { await model.installLanguagePack(pack, deviceID: watchID) }
            },
            installFile: { url in
                Task { await model.installLanguagePack(from: url, deviceID: watchID) }
            }
        )
    }
}

struct LanguageContent: View {
    var packs: [PebbleLanguagePack]
    /// Empty is the firmware's built-in English; nil is a watch that has not
    /// said.
    var installedLocale: String?
    var installedVersion: UInt16?
    var isConnected: Bool
    var isInstalling: Bool
    var progress: PutBytesTransferProgress?
    var statusMessage: LocalizedStringKey?
    var install: (PebbleLanguagePack) -> Void
    var installFile: (URL) -> Void

    @State private var isChoosingFile = false

    private var installedPackLocale: String? {
        guard let installedLocale, !installedLocale.isEmpty else { return nil }
        return installedLocale
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("On the Watch") {
                    if let installedPackLocale {
                        Text(verbatim: languageName(for: installedPackLocale))
                    } else if isConnected {
                        Text("English (built in)")
                    } else {
                        Text("Unknown")
                    }
                }
                if let installedVersion, installedVersion > 0 {
                    LabeledContent("Pack Version", value: installedVersion, format: .number)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let progress, progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.bytesSent), total: Double(progress.totalBytes))
                }
            }

            Section {
                ForEach(packs) { pack in
                    Button {
                        install(pack)
                    } label: {
                        LabeledContent {
                            if pack.locale == installedPackLocale {
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
                    .disabled(!isConnected || isInstalling)
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
                .disabled(!isConnected || isInstalling)
            } footer: {
                Text("A PBL pack built for this watch's board. A pack built for another board installs but shows the wrong glyphs.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Language")
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.pebbleLanguagePack]) { result in
            guard case .success(let url) = result else { return }
            installFile(url)
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

#Preview("Japanese installed") {
    NavigationStack {
        LanguageContent(
            packs: PebbleLanguagePackCatalog.packs(for: .obelixPVT),
            installedLocale: "ja_JP",
            installedVersion: 1,
            isConnected: true,
            isInstalling: false,
            progress: nil,
            statusMessage: nil,
            install: { _ in },
            installFile: { _ in }
        )
    }
}

#Preview("Installing, watch away") {
    NavigationStack {
        LanguageContent(
            packs: PebbleLanguagePackCatalog.packs(for: .obelixPVT),
            installedLocale: "",
            installedVersion: 0,
            isConnected: false,
            isInstalling: true,
            progress: PreviewSamples.transferProgress,
            statusMessage: "日本語 is being sent to the watch.",
            install: { _ in },
            installFile: { _ in }
        )
    }
}
