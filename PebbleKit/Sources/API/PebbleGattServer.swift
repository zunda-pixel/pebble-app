public import CoreBluetooth
import Foundation

/// Hosts the protocol service on the phone so a watch that does not publish
/// one of its own can talk to it as a GATT client ("forward" transport).
///
/// A freshly reset watch, and any watch running recovery firmware, only
/// exposes its pairing service and expects the phone to carry the session.
/// Watches inspect the phone's GATT database right after connecting, so the
/// service has to be published before any connection is attempted — hence the
/// single shared instance, published at launch and shared by every connection.
@MainActor
public final class PebbleGattServer: NSObject {
    public static let shared = PebbleGattServer()

    public static var serviceUUID: CBUUID { CBUUID(string: "10000000-328E-0FBB-C642-1AA6699BDADA") }
    public static var dataCharacteristicUUID: CBUUID { CBUUID(string: "10000001-328E-0FBB-C642-1AA6699BDADA") }
    public static var metaCharacteristicUUID: CBUUID { CBUUID(string: "10000002-328E-0FBB-C642-1AA6699BDADA") }
    /// A second service the watch expects to find alongside the protocol one.
    /// Its contents are never used; only its presence matters.
    public static var fakeServiceUUID: CBUUID { CBUUID(string: "BADBADBA-DBAD-BADB-ADBA-BADBADBADBAD") }

    /// The answer to any read on the phone's server. The watch checks the shape
    /// of this value while setting the session up and gives up on anything else.
    private static let metaResponse = Data([
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    /// Callbacks for one watch, keyed by the identifier CoreBluetooth uses for
    /// it in both the central and peripheral roles.
    private struct Registration {
        var onReceive: (_ bytes: [UInt8]) -> Void
        var onSubscribe: () -> Void
        var onUnsubscribe: () -> Void
    }

    private var peripheralManager: CBPeripheralManager!
    private var dataCharacteristic: CBMutableCharacteristic?
    private var registrations: [String: Registration] = [:]
    private var subscribedCentrals: [String: CBCentral] = [:]
    private var pendingNotifications: [(centralID: String, value: Data)] = []
    private var isServicePublished = false
    private var didRestoreService = false
    private var hasRefreshedRestoredService = false

    private override init() {
        super.init()
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "dev.pebble.ppog.server"]
        )
    }

    /// Publishes the service. Safe to call repeatedly and before the radio is
    /// available; publishing then happens as soon as it powers on.
    public func start() {
        guard peripheralManager.state == .poweredOn, !isServicePublished else {
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
        peripheralManager.add(service)

        let fakeService = CBMutableService(type: Self.fakeServiceUUID, primary: true)
        fakeService.characteristics = [
            CBMutableCharacteristic(
                type: Self.fakeServiceUUID,
                properties: .read,
                value: nil,
                permissions: .readable
            )
        ]
        peripheralManager.add(fakeService)
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
        // The watch may have subscribed before the connection got this far.
        if subscribedCentrals[centralID] != nil {
            onSubscribe()
        }
    }

    func unregister(centralID: String) {
        registrations[centralID] = nil
        pendingNotifications.removeAll { $0.centralID == centralID }
    }

    func isSubscribed(centralID: String) -> Bool {
        subscribedCentrals[centralID] != nil
    }

    /// Removes and re-adds the service, which sends a service-changed
    /// indication. A watch that inspected this phone before the service
    /// existed caches that result and only looks again when told to.
    func republish() {
        guard peripheralManager.state == .poweredOn else {
            return
        }
        Task {
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "Re-publishing the phone's protocol service"
            )
        }
        peripheralManager.removeAllServices()
        // Subscriptions do not survive the service they belong to.
        subscribedCentrals.removeAll()
        pendingNotifications.removeAll()
        dataCharacteristic = nil
        isServicePublished = false
        start()
    }

    /// The largest notification the watch will accept, which depends on the
    /// MTU it negotiated.
    func maximumPacketSize(centralID: String) -> Int {
        subscribedCentrals[centralID]?.maximumUpdateValueLength ?? 20
    }

    /// Sends one PPoG packet to a subscribed watch.
    @discardableResult
    func send(_ bytes: [UInt8], to centralID: String) -> Bool {
        guard let dataCharacteristic, let central = subscribedCentrals[centralID] else {
            return false
        }
        let value = Data(bytes)
        guard peripheralManager.updateValue(
            value,
            for: dataCharacteristic,
            onSubscribedCentrals: [central]
        ) else {
            // The transmit queue is full; retry once CoreBluetooth drains it.
            pendingNotifications.append((centralID, value))
            return true
        }
        return true
    }

    private func flushPendingNotifications() {
        guard let dataCharacteristic else {
            return
        }
        while let pending = pendingNotifications.first {
            guard let central = subscribedCentrals[pending.centralID] else {
                pendingNotifications.removeFirst()
                continue
            }
            guard peripheralManager.updateValue(
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

extension PebbleGattServer: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            return
        }
        // A service iOS restored from the previous launch is still in the
        // database, but no watch was told about it. Re-publishing sends a
        // service-changed indication so a watch that cached the old database
        // discovers the service again.
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
            await PebbleDiagnostics.shared.record(
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
        // Publishing failed; let a later attempt try again.
        isServicePublished = false
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard request.characteristic.uuid == Self.dataCharacteristicUUID,
                  let value = request.value else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            registrations[request.central.identifier.uuidString]?.onReceive([UInt8](value))
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        Task { [uuid = request.characteristic.uuid.uuidString] in
            await PebbleDiagnostics.shared.record(
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
        Task {
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "Watch subscribed to the phone's protocol service"
            )
        }
        registrations[centralID]?.onSubscribe()
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
        pendingNotifications.removeAll { $0.centralID == centralID }
        registrations[centralID]?.onUnsubscribe()
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushPendingNotifications()
    }
}
