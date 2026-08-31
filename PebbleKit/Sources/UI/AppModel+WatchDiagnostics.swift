import API
import Foundation
import SwiftUI

/// What the watch can tell about itself: a picture of its screen, the log it
/// keeps in flash, the log its apps write, and the dump it saves when it
/// crashes.
///
/// All four are pulls — the watch sends nothing until asked — and all four take
/// a while, so each reports where it has got to rather than leaving the screen
/// still.
extension AppModel {
    public func takeScreenshot(deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            watchDiagnosticsStatusMessage = "Connect the watch before taking a screenshot."
            return
        }
        isTakingScreenshot = true
        defer { isTakingScreenshot = false }
        do {
            let screenshot = try await connection.client.takeScreenshot()
            latestScreenshot = screenshot
            screenshotURL = try writeScreenshot(screenshot, name: connection.device.name)
            watchDiagnosticsStatusMessage = nil
        } catch {
            watchDiagnosticsStatusMessage = "The watch would not send a screenshot."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "screenshot",
                message: "\(connection.device.name): \(String(reflecting: error))"
            )
        }
    }

    /// Reads the watch's log back, one generation at a time.
    ///
    /// Generation zero is the run it is in now, one the run before that, and so
    /// on until the watch says it has no more — which is the only way to know
    /// how far back it goes.
    public func gatherWatchLogs(deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            watchDiagnosticsStatusMessage = "Connect the watch before gathering its logs."
            return
        }
        isGatheringWatchLogs = true
        defer { isGatheringWatchLogs = false }
        watchLogLines = []
        do {
            for generation in UInt8(0)..<UInt8(Self.maximumLogGenerations) {
                guard let lines = try await connection.client.readLogGeneration(generation) else {
                    break
                }
                watchLogLines += lines
            }
            watchLogsURL = try writeWatchLogs(name: connection.device.name)
            watchDiagnosticsStatusMessage = nil
        } catch {
            // Whatever arrived before the failure is still worth keeping: a log
            // that stops halfway is more use than none.
            watchLogsURL = try? writeWatchLogs(name: connection.device.name)
            watchDiagnosticsStatusMessage = "The watch stopped part way through its logs."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "watchlog",
                message: "\(connection.device.name): \(String(reflecting: error))"
            )
        }
    }

    /// The watch only sends what its apps log while it has been told to, and it
    /// forgets on the next connection, so this is asked for again each time.
    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async {
        isApplicationLoggingEnabled = isEnabled
        for connection in activeConnections {
            try? await connection.client.setApplicationLoggingEnabled(isEnabled)
        }
        if !isEnabled { applicationLogLines = [] }
    }

    func synchronizeApplicationLogging(on connection: WatchConnection) async {
        guard isApplicationLoggingEnabled, connection.isConnected else { return }
        try? await connection.client.setApplicationLoggingEnabled(true)
    }

    func recordApplicationLogLine(_ line: WatchLogLine, from applicationID: UUID) {
        let name = (watchApplications + watchfaces)
            .first { $0.id == applicationID }?
            .displayName
        var line = line
        if let name { line.file = "\(name) \(line.file)" }
        applicationLogLines.append(line)
        if applicationLogLines.count > 500 {
            applicationLogLines.removeFirst(applicationLogLines.count - 500)
        }
    }

    /// Pulls the dump the watch wrote when it last crashed.
    ///
    /// The unread one is asked for first: the watch marks a dump as read once
    /// it has handed it over, so asking for that one tells us whether this is a
    /// crash nobody has looked at yet.
    public func collectCoredump(deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            watchDiagnosticsStatusMessage = "Connect the watch before collecting a crash report."
            return
        }
        isCollectingCoredump = true
        defer { isCollectingCoredump = false }
        do {
            let bytes = try await connection.client.getBytes(.unreadCoredump)
            guard !bytes.isEmpty else {
                watchDiagnosticsStatusMessage = "The watch has no crash report that has not been read."
                return
            }
            coredumpURL = try write(bytes, name: "\(connection.device.name)-coredump.bin")
            watchDiagnosticsStatusMessage = nil
        } catch GetBytesError.refused(3) {
            watchDiagnosticsStatusMessage = "The watch has no crash report."
        } catch {
            watchDiagnosticsStatusMessage = "The crash report could not be read."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "coredump",
                message: "\(connection.device.name): \(String(reflecting: error))"
            )
        }
    }

    static var maximumLogGenerations: Int { 16 }

    private func writeWatchLogs(name: String) throws -> URL {
        let text = watchLogLines.map(\.formatted).joined(separator: "\n")
        return try write(Array(text.utf8), name: "\(name)-logs.txt")
    }

    /// The picture as a PNG, which is what anything the reader sends it to will
    /// expect.
    private func writeScreenshot(_ screenshot: PebbleScreenshot, name: String) throws -> URL {
        guard let data = WatchImageRenderer.pngData(screenshot) else {
            throw WatchDiagnosticsError.pictureCouldNotBeWritten
        }
        return try write(Array(data), name: "\(name)-screenshot.png")
    }

    private func write(_ bytes: [UInt8], name: String) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "PebbleDiagnostics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name.replacingOccurrences(of: "/", with: "-"))
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }
}

public enum WatchDiagnosticsError: Error, Equatable, Sendable {
    case pictureCouldNotBeWritten
}
