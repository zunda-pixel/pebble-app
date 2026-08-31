import API
import SwiftUI

/// What the watch can be asked about itself.
struct WatchDiagnosticsView: View {
    var model: AppModel
    var watchID: String

    private var isConnected: Bool {
        model.connections.first { $0.device.id == watchID }?.isConnected == true
    }

    var body: some View {
        List {
            Section {
                Button("Take Screenshot", systemImage: "camera") {
                    Task { await model.takeScreenshot(deviceID: watchID) }
                }
                .disabled(!isConnected || model.isTakingScreenshot)
                if let screenshot = model.latestScreenshot,
                   let image = WatchScreenshotImage(screenshot: screenshot).image {
                    image
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("The watch's screen")
                }
                if let url = model.screenshotURL {
                    ShareLink(item: url) { Label("Share Screenshot", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Screen")
            }

            Section {
                Button("Gather Watch Logs", systemImage: "doc.text.magnifyingglass") {
                    Task { await model.gatherWatchLogs(deviceID: watchID) }
                }
                .disabled(!isConnected || model.isGatheringWatchLogs)
                if !model.watchLogLines.isEmpty {
                    LabeledContent("Lines") { Text("\(model.watchLogLines.count)") }
                }
                if let url = model.watchLogsURL {
                    ShareLink(item: url) { Label("Share Logs", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Watch Logs")
            } footer: {
                Text("The watch keeps a log of each run in flash. Gathering reads them back until it says it has no more.")
            }

            Section {
                Toggle("App Logs", isOn: Binding(
                    get: { model.isApplicationLoggingEnabled },
                    set: { isOn in Task { await model.setApplicationLoggingEnabled(isOn) } }
                ))
                ForEach(model.applicationLogLines.suffix(50).reversed()) { line in
                    Text(verbatim: line.formatted)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                }
            } header: {
                Text("App Logs")
            } footer: {
                Text("What the apps on the watch write while this is on. The watch forgets on the next connection, so it is asked again each time.")
            }

            Section {
                Button("Collect Crash Report", systemImage: "exclamationmark.triangle") {
                    Task { await model.collectCoredump(deviceID: watchID) }
                }
                .disabled(!isConnected || model.isCollectingCoredump)
                if let url = model.coredumpURL {
                    ShareLink(item: url) { Label("Share Crash Report", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Crash Report")
            } footer: {
                Text("The dump the watch saved the last time it restarted unexpectedly. It is marked as read once collected, so a second attempt finds nothing.")
            }

            if let message = model.watchDiagnosticsStatusMessage {
                Section {
                    Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}

/// A picture the watch sent, ready to show.
struct WatchScreenshotImage {
    var screenshot: PebbleScreenshot

    var image: Image? {
        guard let cgImage = WatchImageRenderer.makeImage(screenshot) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
