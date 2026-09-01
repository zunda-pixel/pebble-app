import API
import Defaults
public import Foundation
import MemberwiseInit
import SwiftUI

/// A reply chosen on the watch that is waiting for someone to send it.
@MemberwiseInit(.public)
public struct WatchReply: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var text: String
    /// Who it is for, as the watch had them: the number or the address the Send
    /// Text app was opened on.
    public var recipient: String?
    public var date: Date = .now

    /// Messages, opened at a new message with the reply already written.
    ///
    /// The body rides on `&`, not `?`: the `sms:` scheme is not a URL with a
    /// query, and Messages ignores a body handed to it as one. Which also means
    /// the whole thing is escaped here and handed over as it stands — left to
    /// escape it, Foundation escapes the escapes.
    public var composeURL: URL? {
        let address = (recipient ?? "").filter { !$0.isWhitespace }
        guard let escaped = text.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~@"))
        ) else { return nil }
        return URL(string: "sms:\(address)&body=\(escaped)", encodingInvalidCharacters: false)
    }
}

/// The replies waiting to be sent, kept on disk.
///
/// A reply can arrive while the app is in the background and be read minutes
/// later; holding it in memory alone loses it the moment iOS reclaims the app.
actor WatchReplyLibrary {
    private var fileURL: URL

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL
            ?? base.appending(path: "Pebble", directoryHint: .isDirectory).appending(path: "replies.json")
    }

    func replies() throws -> [WatchReply] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([WatchReply].self, from: Data(contentsOf: fileURL))
    }

    func save(_ replies: [WatchReply]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(replies).write(to: fileURL, options: .atomic)
    }
}

/// The short replies the watch offers, and what happens when one is chosen.
///
/// The watch does the choosing and the phone does the sending — except that on
/// iOS the phone cannot: no public API sends a message without the reader
/// tapping Send. So a reply is kept here and the watch is told, plainly, that
/// it did not go.
extension AppModel {
    /// What a watch is given when the reader has not written a list of their
    /// own. The firmware has replies of its own for an empty list, but they are
    /// in the watch's language rather than the phone's.
    public static var defaultCannedReplies: [String] {
        [
            String(localized: "OK", bundle: .module),
            String(localized: "Yes", bundle: .module),
            String(localized: "No", bundle: .module),
            String(localized: "Call me", bundle: .module),
            String(localized: "I'll call you later", bundle: .module),
            String(localized: "On my way", bundle: .module),
        ]
    }

    func loadCannedReplies() {
        let stored = Defaults[.cannedReplies]
        cannedReplies = stored.isEmpty ? Self.defaultCannedReplies : stored
    }

    func loadUnsentReplies() async {
        unsentReplies = (try? await replyLibrary.replies()) ?? []
    }

    public func setCannedReplies(_ replies: [String]) async {
        cannedReplies = replies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        Defaults[.cannedReplies] = cannedReplies
        for connection in activeConnections {
            await synchronizeCannedReplies(on: connection)
        }
    }

    public func addCannedReply(_ reply: String) async {
        await setCannedReplies(cannedReplies + [reply])
    }

    public func removeCannedReplies(at offsets: IndexSet) async {
        var replies = cannedReplies
        replies.remove(atOffsets: offsets)
        await setCannedReplies(replies)
    }

    /// Gives the watch's Send Text app its reply action. The app hides itself
    /// when this record has none, so this is also what makes it appear.
    func synchronizeCannedReplies(on connection: WatchConnection) async {
        guard connection.isConnected, !connection.device.isRunningRecoveryFirmware else { return }
        do {
            try await connection.client.writeNotificationSourceApp(NotificationSourceApp(
                bundleID: NotificationAppsCodec.sendTextKey,
                displayName: "Send Text",
                cannedReplies: cannedReplies
            ))
        } catch {
            await PebbleDiagnostics.shared.record(
                .error,
                category: "notification",
                message: "\(connection.device.name) rejected the reply list: \(String(reflecting: error))"
            )
        }
    }

    func handleWatchReply(_ invocation: TimelineActionInvocation, from connection: WatchConnection) async {
        guard let text = invocation.responseText else { return }
        let reply = WatchReply(text: text, recipient: invocation.recipient)
        unsentReplies.append(reply)
        if unsentReplies.count > 20 { unsentReplies.removeFirst(unsentReplies.count - 20) }
        try? await replyLibrary.save(unsentReplies)
        // Answered as a failure because it is one: the message has not been
        // sent, and saying otherwise would leave the reader believing it had.
        try? await connection.client.respondToTimelineAction(
            itemID: invocation.itemID,
            succeeded: false,
            icon: .failed,
            subtitle: String(localized: "Finish in the app", bundle: .module)
        )
        await PebbleDiagnostics.shared.record(
            category: "notification",
            message: "A reply chosen on the watch is waiting to be sent from the phone"
        )
    }

    public func discardReply(_ reply: WatchReply) {
        unsentReplies.removeAll { $0.id == reply.id }
        let remaining = unsentReplies
        Task { [replyLibrary] in try? await replyLibrary.save(remaining) }
    }
}
