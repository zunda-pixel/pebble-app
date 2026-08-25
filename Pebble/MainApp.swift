import SwiftUI
import UI

@main
struct MainApp: App {
  var body: some Scene {
    WindowGroup {
      #if os(macOS)
      if ProcessInfo.processInfo.environment["PEBBLE_QEMU"] == "1"
          || CommandLine.arguments.contains("--qemu") {
        ContentView(client: makeQEMUPebbleClient())
      } else {
        ContentView()
      }
      #else
      ContentView()
      #endif
    }
    #if os(macOS)
    .commands {
      CommandMenu("Pebble") {
        Button("Scan for Watches") {
          NotificationCenter.default.post(name: .pebbleScanRequested, object: nil)
        }
        .keyboardShortcut("r", modifiers: .command)

        Divider()

        ForEach(Array(["devices", "apps", "timeline", "health", "catalog"].enumerated()), id: \.element) { index, section in
          Button(section.capitalized) {
            NotificationCenter.default.post(name: .pebbleSectionRequested, object: section)
          }
          .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }

        Divider()

        Button("Settings") {
          NotificationCenter.default.post(name: .pebbleSectionRequested, object: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }
    #endif
  }
}
