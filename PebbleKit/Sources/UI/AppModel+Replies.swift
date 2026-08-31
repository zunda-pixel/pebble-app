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
    /// Who it is for, as the watch had them — the number the Send Text app was
    /// opened on.
    public var recipient: String?
    public var date: Date = .now

    /// Messages, opened at a new message to that number with the reply already
    /// written. Sending it is still a tap: iOS has no way for an app to send a
    /// message on its own.
    public var composeURL: URL? {
        var components = URLComponents()
        components.scheme = "sms"
        components.path = recipient?.filter { $0.isNumber || $0 == "+" } ?? ""
        components.queryItems = [URLQueryItem(name: "body", value: text)]
        return components.url
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
            String(localized: "OK"),
            String(localized: "Yes"),
            String(localized: "No"),
            String(localized: "Call me"),
            String(localized: "I'll call you later"),
            String(localized: "On my way"),
        ]
    }

    func loadCannedReplies() {
        let stored = Defaults[.cannedReplies]
        cannedReplies = stored.isEmpty ? Self.defaultCannedReplies : stored
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
        // Answered as a failure because it is one: the message has not been
        // sent, and saying otherwise would leave the reader believing it had.
        try? await connection.client.respondToTimelineAction(
            itemID: invocation.itemID,
            succeeded: false,
            subtitle: String(localized: "Finish in the app")
        )
        await PebbleDiagnostics.shared.record(
            category: "notification",
            message: "A reply chosen on the watch is waiting to be sent from the phone"
        )
    }

    public func discardReply(_ reply: WatchReply) {
        unsentReplies.removeAll { $0.id == reply.id }
    }
}
