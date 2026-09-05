import PebbleProtocol
import SwiftUI

struct WatchDiagnosticsView: View {
    var model: AppModel
    var watchID: WatchID

    private var isConnected: Bool {
        model.connections.first { $0.watch.id == watchID }?.isConnected == true
    }

    var body: some View {
        WatchDiagnosticsContent(
            isConnected: isConnected,
            screenshot: model.diagnostics.latestScreenshot,
            screenshotURL: model.diagnostics.screenshotURL,
            isTakingScreenshot: model.diagnostics.isTakingScreenshot,
            watchLogLineCount: model.diagnostics.watchLogLines.count,
            watchLogsURL: model.diagnostics.watchLogsURL,
            isGatheringWatchLogs: model.diagnostics.isGatheringWatchLogs,
            isApplicationLoggingEnabled: model.diagnostics.isApplicationLoggingEnabled,
            applicationLogLines: model.diagnostics.applicationLogLines,
            coredumpURL: model.diagnostics.coredumpURL,
            isCollectingCoredump: model.diagnostics.isCollectingCoredump,
            feedback: model.diagnostics.feedback,
            takeScreenshot: { Task { await model.takeScreenshot(watchID: watchID) } },
            gatherWatchLogs: { Task { await model.gatherWatchLogs(watchID: watchID) } },
            setApplicationLogging: { isOn in Task { await model.setApplicationLoggingEnabled(isOn) } },
            collectCoredump: { Task { await model.collectCoredump(watchID: watchID) } },
            clearTimeline: { Task { await model.clearWatchTimeline(watchID: watchID) } }
        )
    }
}

/// What the watch can be asked about itself.
struct WatchDiagnosticsContent: View {
    var isConnected: Bool
    var screenshot: WatchScreenshot?
    var screenshotURL: URL?
    var isTakingScreenshot: Bool
    var watchLogLineCount: Int
    var watchLogsURL: URL?
    var isGatheringWatchLogs: Bool
    var isApplicationLoggingEnabled: Bool
    var applicationLogLines: [WatchLogLine]
    var coredumpURL: URL?
    var isCollectingCoredump: Bool
    var feedback: [WatchDiagnostic: FeatureFeedback]
    var takeScreenshot: () -> Void
    var gatherWatchLogs: () -> Void
    var setApplicationLogging: (Bool) -> Void
    var collectCoredump: () -> Void
    var clearTimeline: () -> Void

    var body: some View {
        List {
            Section {
                Button("Take Screenshot", systemImage: "camera", action: takeScreenshot)
                    .disabled(!isConnected || isTakingScreenshot)
                if let screenshot,
                   let image = WatchScreenshotImage(screenshot: screenshot).image {
                    image
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("The watch's screen"))
                }
                if let screenshotURL {
                    ShareLink(item: screenshotURL) { Label("Share Screenshot", systemImage: "square.and.arrow.up") }
                }
                FeedbackBanner(feedback: feedback[.screenshot])
            } header: {
                Text("Screen")
            }

            Section {
                Button("Gather Watch Logs", systemImage: "doc.text.magnifyingglass", action: gatherWatchLogs)
                    .disabled(!isConnected || isGatheringWatchLogs)
                if watchLogLineCount > 0 {
                    LabeledContent("Lines") { Text("\(watchLogLineCount)") }
                }
                if let watchLogsURL {
                    ShareLink(item: watchLogsURL) { Label("Share Logs", systemImage: "square.and.arrow.up") }
                }
                FeedbackBanner(feedback: feedback[.watchLogs])
            } header: {
                Text("Watch Logs")
            } footer: {
                Text("The watch keeps a log of each run in flash. Gathering reads them back until it says it has no more.")
            }

            Section {
                Toggle("App Logs", isOn: Binding(
                    get: { isApplicationLoggingEnabled },
                    set: { isOn in setApplicationLogging(isOn) }
                ))
                ForEach(applicationLogLines.suffix(50).reversed()) { line in
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
                Button("Collect Crash Report", systemImage: "exclamationmark.triangle", action: collectCoredump)
                    .disabled(!isConnected || isCollectingCoredump)
                if let coredumpURL {
                    ShareLink(item: coredumpURL) { Label("Share Crash Report", systemImage: "square.and.arrow.up") }
                }
                FeedbackBanner(feedback: feedback[.coredump])
            } header: {
                Text("Crash Report")
            } footer: {
                Text("The dump the watch saved the last time it restarted unexpectedly. It is marked as read once collected, so a second attempt finds nothing.")
            }

            Section {
                ConfirmingButton(
                    title: "Clear the Watch's Timeline",
                    systemImage: "trash",
                    role: .destructive,
                    question: "Clear every pin from this watch?",
                    explanation: "Every pin on the watch is removed, including any this app did not send, and then the app writes back what it has.",
                    confirmationTitle: "Clear Timeline",
                    action: clearTimeline
                )
                .disabled(!isConnected)
                FeedbackBanner(feedback: feedback[.timeline])
            } header: {
                Text("Timeline")
            } footer: {
                Text("A pin the app no longer has is removed on the next synchronization. This is for the ones it has no record of — after a reinstall, or when its queue was lost.")
            }
        }
        .navigationTitle(Text("Diagnostics"))
    }
}

/// How the last attempt went, in the section that asked. The screen's buttons
/// are sections apart and the app logs section can be fifty lines long, so a
/// result gathered anywhere else is off the screen from whatever caused it.
/// A picture the watch sent, ready to show.
struct WatchScreenshotImage {
    var screenshot: WatchScreenshot

    var image: Image? {
        guard let cgImage = WatchImageRenderer.makeImage(screenshot) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}

#Preview("Connected") {
    NavigationStack {
        WatchDiagnosticsContent(
            isConnected: true,
            screenshot: nil,
            screenshotURL: nil,
            isTakingScreenshot: false,
            watchLogLineCount: PreviewSamples.logLines.count,
            watchLogsURL: nil,
            isGatheringWatchLogs: false,
            isApplicationLoggingEnabled: true,
            applicationLogLines: PreviewSamples.logLines,
            coredumpURL: nil,
            isCollectingCoredump: false,
            feedback: [.watchLogs: .success("3 log line(s) collected.")],
            takeScreenshot: {},
            gatherWatchLogs: {},
            setApplicationLogging: { _ in },
            collectCoredump: {},
            clearTimeline: {}
        )
    }
}

#Preview("Away") {
    NavigationStack {
        WatchDiagnosticsContent(
            isConnected: false,
            screenshot: nil,
            screenshotURL: nil,
            isTakingScreenshot: false,
            watchLogLineCount: 0,
            watchLogsURL: nil,
            isGatheringWatchLogs: false,
            isApplicationLoggingEnabled: false,
            applicationLogLines: [],
            coredumpURL: nil,
            isCollectingCoredump: false,
            feedback: [:],
            takeScreenshot: {},
            gatherWatchLogs: {},
            setApplicationLogging: { _ in },
            collectCoredump: {},
            clearTimeline: {}
        )
    }
}
