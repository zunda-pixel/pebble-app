import PebbleProtocol
public import CoreBluetooth
import Foundation

/// Hosts the protocol service on the phone, which a watch that does not
/// publish one of its own — a freshly reset one, or any watch running recovery
/// firmware — connects to as a GATT client.
@MainActor
public final class GATTServer: NSObject {
    public static let shared = GATTServer()

    public static var serviceUUID: CBUUID { CBUUID(string: "10000000-328E-0FBB-C642-1AA6699BDADA") }
    public static var dataCharacteristicUUID: CBUUID { CBUUID(string: "10000001-328E-0FBB-C642-1AA6699BDADA") }
    public static var metaCharacteristicUUID: CBUUID { CBUUID(string: "10000002-328E-0FBB-C642-1AA6699BDADA") }
    /// A second service the watch expects to find alongside the protocol one.
    /// Its contents are never used; only its presence matters.
    public static var fakeServiceUUID: CBUUID { CBUUID(string: "BADBADBA-DBAD-BADB-ADBA-BADBADBADBAD") }

    /// The watch checks the shape of this value while setting the session up and
    /// gives up on anything else.
    private static let metaResponse = Data([
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    /// Keyed by the identifier CoreBluetooth uses for a watch in both the central
    /// and peripheral roles.
    private struct Registration {
        var onReceive: (_ bytes: [UInt8]) -> Void
        var onSubscribe: () -> Void
        var onUnsubscribe: () -> Void
    }

    /// A watch that has been set up reconnects on its own and starts talking to
    /// the phone's service without the app having scanned for it.
    public var onUnclaimedWatch: ((_ centralID: String) -> Void)?

    private var peripheralManager: CBPeripheralManager?
    private var dataCharacteristic: CBMutableCharacteristic?
    private var registrations: [String: Registration] = [:]
    private var subscribedCentrals: [String: CBCentral] = [:]
    private var pendingNotifications = PendingNotificationQueue()
    private var isServicePublished = false
    private var didRestoreService = false
    private var hasRefreshedRestoredService = false

    private override init() {
        super.init()
    }

    /// Publishes the service, making the peripheral manager on the way if there
    /// is not one yet.
    ///
    /// The manager is not made in `init` because making one raises the system's
    /// Bluetooth dialog, and `shared` is touched while the app is starting — to
    /// hang the reconnect handler on, which needs no radio. The radio is opened
    /// when a watch is actually wanted.
    public func start() {
        guard let manager = peripheralManager else {
            peripheralManager = CBPeripheralManager(
                delegate: self,
                queue: .main,
                options: [CBPeripheralManagerOptionRestoreIdentifierKey: "dev.pebble.ppog.server"]
            )
            // Nothing can be published until the radio answers, and it answers
            // by calling back here.
            return
        }
        guard manager.state == .poweredOn, !isServicePublished else {
            return
        }
        isServicePublished = true

        let meta = CBMutableCharacteristic(
            type: Self.metaCharacteristicUUID,
            properties: .read,
            value: nil,
            permissions: .readable
        )
        let data = CBMutableCharacteristic(
            type: Self.dataCharacteristicUUID,
            properties: [.writeWithoutResponse, .notify],
            value: nil,
            permissions: .writeable
        )
        dataCharacteristic = data

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [meta, data]
        manager.add(service)

        let fakeService = CBMutableService(type: Self.fakeServiceUUID, primary: true)
        fakeService.characteristics = [
            CBMutableCharacteristic(
                type: Self.fakeServiceUUID,
                properties: .read,
                value: nil,
                permissions: .readable
            )
        ]
        manager.add(fakeService)
    }

    func register(
        centralID: String,
        onReceive: @escaping (_ bytes: [UInt8]) -> Void,
        onSubscribe: @escaping () -> Void,
        onUnsubscribe: @escaping () -> Void
    ) {
        registrations[centralID] = Registration(
            onReceive: onReceive,
            onSubscribe: onSubscribe,
            onUnsubscribe: onUnsubscribe
        )
        if subscribedCentrals[centralID] != nil {
            onSubscribe()
        }
    }

    func unregister(centralID: String) {
        registrations[centralID] = nil
        pendingNotifications.removeAll(for: centralID)
        // iOS does not always report an unsubscribe, and leaving the record would
        // make the next link look ready before the watch has subscribed to it.
        subscribedCentrals[centralID] = nil
    }

    func isSubscribed(centralID: String) -> Bool {
        subscribedCentrals[centralID] != nil
    }

    // Removing and re-adding sends a service-changed indication. A watch that
    // inspected this phone before the service existed caches that result.
    //
    // `chasing` names the one watch the republish is for. The teardown is
    // global — one peripheral manager, every subscriber — so while any *other*
    // watch is subscribed and talking, cutting its transport to chase this one
    // is the worse trade, and the stalled watch gets its retry on the next
    // connect instead.
    func republish(chasing centralID: String? = nil) {
        guard let manager = peripheralManager, manager.state == .poweredOn else {
            return
        }
        let others = subscribedCentrals.keys.filter { $0 != centralID }
        guard others.isEmpty else {
            Task { [count = others.count] in
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "pairing",
                    message: "Left the phone's protocol service alone: \(count) other watch(es) are subscribed to it"
                )
            }
            return
        }
        Task {
            await DiagnosticLog.shared.record(
                category: "pairing",
                message: "Re-publishing the phone's protocol service"
            )
        }
        manager.removeAllServices()
        forgetPublishedDatabase()
        start()
    }

    /// The local GATT database is empty: removed on purpose by `republish`, or
    /// cleared by iOS, which drops every published service when the
    /// peripheral manager leaves `poweredOn`. Believing the service survived a
    /// power cycle meant `start()` never re-added it, and a subscription left
    /// from before made the next link look subscribed, so the watchdog that
    /// republishes for a watch that never subscribes stood down as well.
    ///
    /// The registered clients are not told their watch unsubscribed: the
    /// central manager leaves `poweredOn` at the same moment and tears each
    /// link down itself, and an abort from here would ask a central that is
    /// not powered on to cancel a connection.
    func forgetPublishedDatabase() {
        isServicePublished = false
        dataCharacteristic = nil
        subscribedCentrals.removeAll()
        pendingNotifications.removeAll()
    }

    func maximumPacketSize(centralID: String) -> Int {
        subscribedCentrals[centralID]?.maximumUpdateValueLength ?? 20
    }

    /// How many packets may wait for iOS to say it is ready again.
    ///
    /// A backlog is normal — iOS refuses a notification when its transmit queue
    /// is full and calls back when it drains — but a backlog that only grows
    /// means the watch is no longer reading. Reporting success into that void is
    /// what turned a dead session into thirty seconds of protocol
    /// retransmissions and then a bare timeout: the protocol's own window is at
    /// most 25 packets, so anything past that is not flow control.
    ///
    /// Counted per watch. One total across every subscriber let a watch that
    /// had stopped reading fill it, and the healthy watch beside it was then
    /// refused a send and had its link dropped for the other's silence.
    static let maximumBacklog = 32

    static func isBacklogged(_ queue: PendingNotificationQueue, for centralID: String) -> Bool {
        queue.count(for: centralID) >= maximumBacklog
    }

    @discardableResult
    func send(_ bytes: [UInt8], to centralID: String) -> Bool {
        guard let manager = peripheralManager,
              let dataCharacteristic,
              let central = subscribedCentrals[centralID] else {
            return false
        }
        guard !Self.isBacklogged(pendingNotifications, for: centralID) else {
            Task {
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "pairing",
                    message: "The phone's protocol service has \(Self.maximumBacklog) packets waiting; the watch is not reading"
                )
            }
            return false
        }
        let value = Data(bytes)
        guard !pendingNotifications.holdsPackets(for: centralID) else {
            pendingNotifications.append(value, for: centralID)
            return true
        }
        guard manager.updateValue(
            value,
            for: dataCharacteristic,
            onSubscribedCentrals: [central]
        ) else {
            pendingNotifications.append(value, for: centralID)
            return true
        }
        return true
    }

    private func flushPendingNotifications() {
        guard let manager = peripheralManager, let dataCharacteristic else {
            return
        }
        while let pending = pendingNotifications.first {
            guard let central = subscribedCentrals[pending.centralID] else {
                // Dropping a protocol packet silently leaves the session
                // retransmitting into a watch that is no longer there.
                pendingNotifications.removeFirst()
                Task { [centralID = pending.centralID] in
                    await DiagnosticLog.shared.record(
                        .warning,
                        category: "pairing",
                        message: "Dropped a packet for a watch that unsubscribed (\(centralID))"
                    )
                }
                continue
            }
            // Stopping here rather than trying the next watch's packet: a
            // refusal means the manager's one transmit queue is full, not this
            // watch's, so every other packet would be refused too.
            guard manager.updateValue(
                pending.value,
                for: dataCharacteristic,
                onSubscribedCentrals: [central]
            ) else {
                return
            }
            pendingNotifications.removeFirst()
        }
    }
}

extension GATTServer: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            forgetPublishedDatabase()
            return
        }
        // A service iOS restored from the previous launch is in the database, but no
        // watch was told about it.
        if didRestoreService, !hasRefreshedRestoredService {
            hasRefreshedRestoredService = true
            republish()
            return
        }
        start()
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        for service in services where service.uuid == Self.serviceUUID {
            isServicePublished = true
            didRestoreService = true
            let characteristics = service.characteristics as? [CBMutableCharacteristic] ?? []
            dataCharacteristic = characteristics.first { $0.uuid == Self.dataCharacteristicUUID }
            for central in dataCharacteristic?.subscribedCentrals ?? [] {
                subscribedCentrals[central.identifier.uuidString] = central
            }
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: (any Error)?
    ) {
        Task { [uuid = service.uuid.uuidString, message = error?.localizedDescription] in
            await DiagnosticLog.shared.record(
                message == nil ? .info : .error,
                category: "pairing",
                message: message == nil
                    ? "Published \(uuid) on the phone's server"
                    : "Could not publish \(uuid): \(message ?? "")"
            )
        }
        guard error != nil else {
            return
        }
        isServicePublished = false
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        // One delivery gets exactly one response, on its first request —
        // answering a refused request in the loop and then the batch again
        // was two responses to the same ATT transaction.
        var result = CBATTError.Code.success
        for request in requests {
            guard request.characteristic.uuid == Self.dataCharacteristicUUID,
                  let value = request.value else {
                result = .requestNotSupported
                continue
            }
            registrations[request.central.identifier.uuidString]?.onReceive([UInt8](value))
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: result)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        Task { [uuid = request.characteristic.uuid.uuidString] in
            await DiagnosticLog.shared.record(
                category: "pairing",
                message: "Watch read \(uuid) from the phone's server"
            )
        }
        request.value = Self.metaResponse
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.dataCharacteristicUUID else {
            return
        }
        let centralID = central.identifier.uuidString
        subscribedCentrals[centralID] = central
        Task { [isClaimed = registrations[centralID] != nil] in
            await DiagnosticLog.shared.record(
                category: "pairing",
                message: isClaimed
                    ? "Watch subscribed to the phone's protocol service"
                    : "Watch subscribed to the phone's protocol service on a link the app does not hold"
            )
        }
        guard let registration = registrations[centralID] else {
            onUnclaimedWatch?(centralID)
            return
        }
        registration.onSubscribe()
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.dataCharacteristicUUID else {
            return
        }
        let centralID = central.identifier.uuidString
        subscribedCentrals[centralID] = nil
        pendingNotifications.removeAll(for: centralID)
        registrations[centralID]?.onUnsubscribe()
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushPendingNotifications()
    }
}
