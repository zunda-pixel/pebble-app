import AccessoryTransportExtension
import ExtensionFoundation
import PebbleForwarding

@main
struct NotificationTransport: AccessoryTransportAppExtension {
    func accept(
        sessionRequest: AccessoryTransportSession.Request
    ) -> AccessoryTransportSession.Request.Decision {
        Transport.accept(sessionRequest)
    }
}
