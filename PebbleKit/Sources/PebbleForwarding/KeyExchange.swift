#if os(iOS)
// Its session types are not marked Sendable (the module is built in Swift 5
// mode), though each is only ever used here from the main actor.
@unsafe @preconcurrency public import AccessoryTransportExtension
import Foundation
import OSLog
import PebbleProtocol

/// The AccessoryTransportSecurity extension's part: the watch is the HPKE
/// recipient, so its public key goes up to iOS and iOS's encapsulated key comes
/// back down to it. Nothing is derived here.
public enum KeyExchange {
    public static func accept(
        _ request: AccessorySecuritySession.Request
    ) -> AccessorySecuritySession.Request.Decision {
        let session = request.session
        Task { @MainActor in offerTheWatchsKey(to: session) }
        return request.accept { Handler() }
    }

    @MainActor
    private static func offerTheWatchsKey(to session: AccessorySecuritySession) {
        let link = WatchAccessoryLink.shared
        let offer: ([UInt8]) -> Void = { key in
            // The watch implements the P-256 suite only; ML-KEM, which X-Wing
            // needs, is not in its mbed TLS.
            let message = SecurityMessage(
                keyType: .publicKey,
                cipherSuite: .p256,
                version: .version1,
                key: Data(key),
                supportedTransports: [.bluetooth]
            )
            do {
                try session.sendSecurityMessage(message)
            } catch {
                forwardingLog.error("iOS refused the watch's key: \(String(describing: error), privacy: .public)")
            }
        }
        link.onNotification = { frame in
            if let key = AccessoryTransportFrame.publicKey(from: frame) {
                offer(key)
            }
        }
        if let key = link.publicKey {
            offer(key)
        }
    }

    final class Handler: AccessorySecuritySession.EventHandler {
        func messageReceived(
            _ message: SecurityMessage,
            completion: @escaping @Sendable (AccessoryMessage.Result) -> Void
        ) {
            guard message.keyType == .encapsulatedKey else {
                completion(.success)
                return
            }
            let key = [UInt8](message.key)
            // The identifier iOS put in the HPKE info, which the watch has to put
            // in its own byte for byte; the peripheral the link reached is the
            // same watch, for an iOS that names none.
            let identifier = message.identifier
            Task { @MainActor in
                do {
                    try await WatchAccessoryLink.shared.write { connection in
                        [try AccessoryTransportFrame.session(
                            encapsulatedKey: key,
                            accessoryIdentifier: identifier ?? connection.peripheralIdentifier.uuidString
                        )]
                    }
                    completion(.success)
                } catch {
                    forwardingLog.error("the watch did not take the session: \(String(describing: error), privacy: .public)")
                    completion(.failure(.transportUnavailable))
                }
            }
        }

        func sessionInvalidated(error: AccessorySecuritySession.Error?) {
            forwardingLog.log("key exchange ended: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
