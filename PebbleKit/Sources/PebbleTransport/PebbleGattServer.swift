import PebbleProtocol
public import CoreBluetooth
import Foundation

/// Hosts the protocol service on the phone, which a watch that does not
/// publish one of its own — a freshly reset one, or any watch running recovery
/// firmware — connects to as a GATT client.
@MainActor
public final class PebbleGattServer: NSObject {
    public static let shared = PebbleGattServer()

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

    private var peripheralManager: CBPeripheralManager!
    private var dataCharacteristic: CBMutableCharacteristic?
    private var registrations: [String: Registration] = [:]
    private var subscribedCentrals: [String: CBCentral] = [:]
    private var pendingNotifications = PendingNotificationQueue()
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
        subscribedCentrals.removeAll()
        pendingNotifications.removeAll()
        dataCharacteristic = nil
        isServicePublished = false
        start()
    }

    func maximumPacketSize(centralID: String) -> Int {
        subscribedCentrals[centralID]?.maximumUpdateValueLength ?? 20
    }

    @discardableResult
    func send(_ bytes: [UInt8], to centralID: String) -> Bool {
        guard let dataCharacteristic, let central = subscribedCentrals[centralID] else {
            return false
        }
        let value = Data(bytes)
        guard !pendingNotifications.holdsPackets(for: centralID) else {
            pendingNotifications.append(value, for: centralID)
            return true
        }
        guard peripheralManager.updateValue(
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
        Task { [isClaimed = registrations[centralID] != nil] in
            await PebbleDiagnostics.shared.record(
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
