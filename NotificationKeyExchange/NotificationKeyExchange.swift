import AccessoryTransportExtension
import ExtensionFoundation
import PebbleForwarding

@main
struct NotificationKeyExchange: AccessoryTransportSecurity {
    func accept(
        sessionRequest: AccessorySecuritySession.Request
    ) -> AccessorySecuritySession.Request.Decision {
        KeyExchange.accept(sessionRequest)
    }
}
