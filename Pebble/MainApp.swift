import SwiftUI
import PebbleApp

@main
struct MainApp: App {
    @State private var model: AppModel

    init() {
#if os(macOS)
        let useQEMU = ProcessInfo.processInfo.environment["PEBBLE_QEMU"] == "1"
            || CommandLine.arguments.contains("--qemu")
        _model = State(initialValue: AppModel(
            client: useQEMU ? makeQEMUWatchClient() : makeDefaultPebbleClient(),
            clientFactory: useQEMU ? nil : makeDefaultWatchClientFactory()
        ))
#else
        _model = State(initialValue: AppModel(
            client: makeDefaultPebbleClient(),
            clientFactory: makeDefaultWatchClientFactory()
        ))
#endif
    }

    var body: some Scene {
#if os(macOS)
        WindowGroup(id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 960, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Pebble") {
                Button("Scan for Watches") {
                    NotificationCenter.default.post(ScanRequest(), subject: model)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isScanningOrConnecting)

                Divider()

                ForEach(AppSection.windowSections) { section in
                    Button {
                        NotificationCenter.default.post(SectionRequest(section: section), subject: model)
                    } label: {
                        section.titleText
                    }
                    .keyboardShortcut(section.keyboardShortcut, modifiers: .command)
                }
            }
        }

        Settings {
            SettingsRootView(model: model)
                .frame(width: 620, height: 680)
        }
#else
        WindowGroup {
            ContentView(model: model)
        }
#endif
    }
}
