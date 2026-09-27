import PebbleProtocol
import CoreBluetooth
import DequeModule
import Foundation

/// What one Bluetooth link to a watch holds while it is up: how far its setup
/// got, the characteristics it found, the PPoG session and the frames half
/// read off it, and the deadlines armed for it.
///
/// One value rather than fields on the client, because it is ended from two
/// places — a connect that failed and a link that dropped — and the two used to
/// list what they reset by hand. The lists had drifted: the failed connect left
/// the frame decoder, the subscription watchdog and the session-restart
/// deadline behind for the next link to trip over. A field added here is reset
/// by both without either being touched.
struct LinkState {
    var setup = LinkSetup()
    var activeWriteCharacteristic: CBCharacteristic?
    var activeBatteryCharacteristic: CBCharacteristic?
    var activePairingTriggerCharacteristic: CBCharacteristic?
    var ppogNotifyCharacteristicToSubscribe: CBCharacteristic?
    var pairingTimeoutTask: Task<Void, Never>?
    var subscriptionWatchdog: Task<Void, Never>?
    var hasRepublishedForThisLink = false
    /// Set once this link has been given up on for services iOS holds out of
    /// date, which three separate callbacks can each find.
    var hasGivenUpOnOutOfDateServices = false
    var ppogSession: PPoGSession?
    var frameDecoder = PebbleProtocolFrameDecoder()
    var pendingGattWrites: Deque<Data> = []
    var acknowledgementTimeoutTask: Task<Void, Never>?
    /// Set while a session started over on a live link waits for the watch to
    /// answer its version request.
    ///
    /// That answer is almost always word for word the one before, and the app
    /// has to hear it anyway: it is the only thing that says the transport is
    /// usable again and the work interrupted by the restart needs re-doing.
    var isRestartingSession = false
    /// Deadline for a session started over on a live link. Without it a watch
    /// that asks for a reset and then says nothing leaves the link up with no
    /// transport on it, and nothing notices until the health check fails a
    /// minute later.
    var sessionRestartTimeoutTask: Task<Void, Never>?
    var latestBatteryLevel: Int?

    /// A deadline that outlives its link tears down the healthy one that
    /// replaced it.
    func cancelDeadlines() {
        pairingTimeoutTask?.cancel()
        subscriptionWatchdog?.cancel()
        acknowledgementTimeoutTask?.cancel()
        sessionRestartTimeoutTask?.cancel()
    }
}
