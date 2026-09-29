#if os(iOS)
// Its session types are not marked Sendable (the module is built in Swift 5
// mode), though each is only ever used here from the main actor.
@unsafe @preconcurrency public import AccessoryTransportExtension
import Foundation
import OSLog
import PebbleProtocol

/// The AccessoryTransportAppExtension's part: sealed messages iOS hands over go
/// to the watch as DATA frames, and the replies the watch seals come back to
/// the data provider. The bytes are never opened here.
public enum Transport {
    public static func accept(
        _ request: AccessoryTransportSession.Request
    ) -> AccessoryTransportSession.Request.Decision {
        let session = request.session
        Task { @MainActor in forwardReplies(to: session) }
        return request.accept { Handler() }
    }

    @MainActor
    private static func forwardReplies(to session: AccessoryTransportSession) {
        var reassembler = AccessoryTransportResponseReassembler()
        WatchAccessoryLink.shared.onLinkDropped = {
            reassembler.reset()
        }
        WatchAccessoryLink.shared.onNotification = { frame in
            guard let response = reassembler.receive(frame) else { return }
            do {
                try session.sendMessageToDataProvider(
                    TransportMessage(sessionID: response.featureID, data: Data(response.sealed))
                )
            } catch {
                forwardingLog.error("a reply from the watch was not taken: \(String(describing: error), privacy: .public)")
            }
        }
    }

    final class Handler: AccessoryTransportSession.EventHandler {
        func messageReceived(
            _ message: TransportMessage,
            completion: @escaping @Sendable (AccessoryMessage.Result) -> Void
        ) {
            let featureID = message.sessionID
            let sealed = [UInt8](message.data)
            Task { @MainActor in
                do {
                    try await WatchAccessoryLink.shared.write { connection in
                        try AccessoryTransportFrame.dataWrites(
                            featureID: featureID,
                            sealed: sealed,
                            maximumWriteLength: connection.maximumWriteLength
                        )
                    }
                    completion(.success)
                } catch {
                    forwardingLog.error("a notification did not reach the watch: \(String(describing: error), privacy: .public)")
                    completion(.failure(.transportUnavailable))
                }
            }
        }

        func sessionInvalidated(error: AccessoryTransportSession.Error?) {
            forwardingLog.log("transport ended: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
