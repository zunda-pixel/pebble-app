public import PebbleProtocol
import Foundation
import SwiftUI

extension AppModel {
    public func takeScreenshot(watchID: WatchID? = nil) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            watchDiagnosticsStatusMessages[.screenshot] = "Connect the watch before taking a screenshot."
            return
        }
        isTakingScreenshot = true
        defer { isTakingScreenshot = false }
        do {
            let screenshot = try await connection.client.takeScreenshot()
            latestScreenshot = screenshot
            screenshotURL = try writeScreenshot(screenshot, name: connection.watch.name)
            watchDiagnosticsStatusMessages[.screenshot] = nil
        } catch {
            watchDiagnosticsStatusMessages[.screenshot] = "The watch would not send a screenshot."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "screenshot",
                message: "\(connection.watch.name): \(String(reflecting: error))"
            )
        }
    }

    /// Generation zero is the run the watch is in now, one the run before that,
    /// and so on until the watch says it has no more.
    public func gatherWatchLogs(watchID: WatchID? = nil) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            watchDiagnosticsStatusMessages[.watchLogs] = "Connect the watch before gathering its logs."
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
            watchLogsURL = try writeWatchLogs(name: connection.watch.name)
            watchDiagnosticsStatusMessages[.watchLogs] = nil
        } catch {
            // A log that stops halfway is more use than none.
            watchLogsURL = try? writeWatchLogs(name: connection.watch.name)
            watchDiagnosticsStatusMessages[.watchLogs] = "The watch stopped part way through its logs."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "watchlog",
                message: "\(connection.watch.name): \(String(reflecting: error))"
            )
        }
    }

    // The watch forgets on the next connection, so this is asked for again each
    // time.
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

    // The unread dump is asked for first: the watch marks one as read once it has
    // handed it over, so asking for that one leaves a dump already collected
    // alone.
    public func collectCoredump(watchID: WatchID? = nil) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            watchDiagnosticsStatusMessages[.coredump] = "Connect the watch before collecting a crash report."
            return
        }
        isCollectingCoredump = true
        defer { isCollectingCoredump = false }
        do {
            let bytes = try await connection.client.getBytes(.unreadCoredump)
            guard !bytes.isEmpty else {
                watchDiagnosticsStatusMessages[.coredump] = "The watch has no crash report that has not been read."
                return
            }
            coredumpURL = try write(bytes, name: "\(connection.watch.name)-coredump.bin")
            watchDiagnosticsStatusMessages[.coredump] = nil
        } catch GetBytesError.refused(3) {
            watchDiagnosticsStatusMessages[.coredump] = "The watch has no crash report."
        } catch {
            watchDiagnosticsStatusMessages[.coredump] = "The crash report could not be read."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "coredump",
                message: "\(connection.watch.name): \(String(reflecting: error))"
            )
        }
    }

    static var maximumLogGenerations: Int { 16 }

    private func writeWatchLogs(name: String) throws -> URL {
        let text = watchLogLines.map(\.formatted).joined(separator: "\n")
        return try write(Array(text.utf8), name: "\(name)-logs.txt")
    }

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
