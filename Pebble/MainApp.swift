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
  }
}
