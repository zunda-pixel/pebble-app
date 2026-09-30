import AccessoryNotifications
import AccessoryTransportExtension
import ExtensionFoundation
import PebbleForwarding

@main
struct NotificationProvider: AccessoryDataProvider {
    var extensionPoint: AppExtensionPoint {
        Identifier("com.apple.accessory-data-provider")
        Implementing {
            NotificationsForwarding { NotificationForwardingHandler() }
        }
    }
}
