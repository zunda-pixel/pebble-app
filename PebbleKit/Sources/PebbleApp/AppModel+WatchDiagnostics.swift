public import PebbleProtocol
import Foundation
import SwiftUI

extension AppModel {
    public func takeScreenshot(watchID: WatchID? = nil) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            diagnostics.feedback[.screenshot] = .failure("Connect the watch before taking a screenshot.")
            return
        }
        diagnostics.isTakingScreenshot = true
        defer { diagnostics.isTakingScreenshot = false }
        do {
            let screenshot = try await connection.client.takeScreenshot()
            diagnostics.latestScreenshot = screenshot
            diagnostics.screenshotURL = try writeScreenshot(screenshot, name: connection.watch.name)
            diagnostics.feedback[.screenshot] = nil
        } catch {
            diagnostics.feedback[.screenshot] = .failure("The watch would not send a screenshot.")
            await DiagnosticLog.shared.record(
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
            diagnostics.feedback[.watchLogs] = .failure("Connect the watch before gathering its logs.")
            return
        }
        diagnostics.isGatheringWatchLogs = true
        defer { diagnostics.isGatheringWatchLogs = false }
        diagnostics.watchLogLines = []
        do {
            for generation in UInt8(0)..<UInt8(Self.maximumLogGenerations) {
                guard let lines = try await connection.client.readLogGeneration(generation) else {
                    break
                }
                diagnostics.watchLogLines += lines
            }
            diagnostics.watchLogsURL = try writeWatchLogs(name: connection.watch.name)
            diagnostics.feedback[.watchLogs] = nil
        } catch {
            // A log that stops halfway is more use than none.
            diagnostics.watchLogsURL = try? writeWatchLogs(name: connection.watch.name)
            diagnostics.feedback[.watchLogs] = .failure("The watch stopped part way through its logs.")
            await DiagnosticLog.shared.record(
                .error,
                category: "watchlog",
                message: "\(connection.watch.name): \(String(reflecting: error))"
            )
        }
    }

    // The watch forgets on the next connection, so this is asked for again each
    // time.
    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async {
        diagnostics.isApplicationLoggingEnabled = isEnabled
        for connection in activeConnections {
            try? await connection.client.setApplicationLoggingEnabled(isEnabled)
        }
        if !isEnabled { diagnostics.applicationLogLines = [] }
    }

    func synchronizeApplicationLogging(on connection: WatchConnection) async {
        guard diagnostics.isApplicationLoggingEnabled, connection.isConnected else { return }
        try? await connection.client.setApplicationLoggingEnabled(true)
    }

    func recordApplicationLogLine(_ line: WatchLogLine, from applicationID: UUID) {
        let name = applications.all
            .first { $0.id == applicationID }?
            .displayName
        var line = line
        if let name { line.file = "\(name) \(line.file)" }
        diagnostics.applicationLogLines.append(line)
        if diagnostics.applicationLogLines.count > 500 {
            diagnostics.applicationLogLines.removeFirst(diagnostics.applicationLogLines.count - 500)
        }
    }

    // The unread dump is asked for first: the watch marks one as read once it has
    // handed it over, so asking for that one leaves a dump already collected
    // alone.
    public func collectCoredump(watchID: WatchID? = nil) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            diagnostics.feedback[.coredump] = .failure("Connect the watch before collecting a crash report.")
            return
        }
        diagnostics.isCollectingCoredump = true
        defer { diagnostics.isCollectingCoredump = false }
        do {
            let bytes = try await connection.client.getBytes(.unreadCoredump)
            guard !bytes.isEmpty else {
                diagnostics.feedback[.coredump] = .success("The watch has no crash report that has not been read.")
                return
            }
            diagnostics.coredumpURL = try write(bytes, name: "\(connection.watch.name)-coredump.bin")
            diagnostics.feedback[.coredump] = nil
        } catch GetBytesError.refused(3) {
            diagnostics.feedback[.coredump] = .success("The watch has no crash report.")
        } catch {
            diagnostics.feedback[.coredump] = .failure("The crash report could not be read.")
            await DiagnosticLog.shared.record(
                .error,
                category: "coredump",
                message: "\(connection.watch.name): \(String(reflecting: error))"
            )
        }
    }

    static var maximumLogGenerations: Int { 16 }

    private func writeWatchLogs(name: String) throws -> URL {
        let text = diagnostics.watchLogLines.map(\.formatted).joined(separator: "\n")
        return try write(Array(text.utf8), name: "\(name)-logs.txt")
    }

    private func writeScreenshot(_ screenshot: WatchScreenshot, name: String) throws -> URL {
        guard let data = WatchImageRenderer.pngData(screenshot) else {
            throw WatchDiagnosticsError.pictureCouldNotBeWritten
        }
        return try write(Array(data), name: "\(name)-screenshot.png")
    }

    private func write(_ bytes: [UInt8], name: String) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "DiagnosticLog")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name.replacingOccurrences(of: "/", with: "-"))
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }
}

public enum WatchDiagnosticsError: Error, Equatable, Sendable {
    case pictureCouldNotBeWritten
}
