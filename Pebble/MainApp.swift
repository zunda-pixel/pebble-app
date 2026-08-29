import SwiftUI
import UI

@main
struct MainApp: App {
  @State private var model: AppModel

  init() {
#if os(macOS)
    let useQEMU = ProcessInfo.processInfo.environment["PEBBLE_QEMU"] == "1"
      || CommandLine.arguments.contains("--qemu")
    _model = State(initialValue: AppModel(
      client: useQEMU ? makeQEMUPebbleClient() : makeDefaultPebbleClient(),
      clientFactory: useQEMU ? nil : makeDefaultPebbleClientFactory()
    ))
#else
    _model = State(initialValue: AppModel(
      client: makeDefaultPebbleClient(),
      clientFactory: makeDefaultPebbleClientFactory()
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
          NotificationCenter.default.post(name: .pebbleScanRequested, object: nil)
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isScanningOrConnecting)

        Divider()

        ForEach(Array(["devices", "apps", "timeline", "health"].enumerated()), id: \.element) { index, section in
          Button(section.capitalized) {
            NotificationCenter.default.post(name: .pebbleSectionRequested, object: section)
          }
          .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }

      }
    }

    Settings {
      PebbleSettingsView(model: model)
        .frame(width: 620, height: 680)
    }
#else
    WindowGroup {
      ContentView(model: model)
    }
#endif
  }
}
