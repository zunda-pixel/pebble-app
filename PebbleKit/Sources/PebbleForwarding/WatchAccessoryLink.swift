#if os(iOS)
internal import AccessorySetupKit
internal import CoreBluetooth
import DequeModule
import Foundation
import OSLog
import PebbleProtocol

let forwardingLog = Logger(subsystem: "com.zunda.Pebble", category: "forwarding")

/// An extension's own link to the watch's AccessoryNotifications service.
///
/// iOS runs each extension in a process of its own and hands none of them the
/// Bluetooth link, so each connects by itself. A central made with
/// `CBCentralManagerOptionDeviceAccessForMedia` reaches the accessories the app
/// paired through AccessorySetupKit, which is all an extension is allowed.
///
/// Neither the key exchange nor the transport session says which watch it is
/// for, so this reaches the one the phone is connected to: iOS forwards to a
/// single notification target at a time.
@MainActor
final class WatchAccessoryLink: NSObject {
    static let shared = WatchAccessoryLink()

    struct Connection {
        var peripheralIdentifier: UUID
        var maximumWriteLength: Int
    }

    enum LinkError: Error {
        case unavailable
        case writeFailed(String)
        case timedOut
    }

    /// Every notification the watch sends on the service, the public key first.
    var onNotification: ((_ frame: [UInt8]) -> Void)?
    /// What the watch last said its public key is. It keeps the key across
    /// reboots and sends it once per subscription, so a session that starts on a
    /// link already subscribed would otherwise never hear it.
    private(set) var publicKey: [UInt8]?

    private struct PendingWrite {
        let id = UUID()
        let makeFrames: (Connection) throws -> [[UInt8]]
        var frames: [[UInt8]]?
        let continuation: CheckedContinuation<Void, any Error>
        var deadline: Task<Void, Never>?
    }

    private var central: CBCentralManager?
    private let accessories = ASAccessorySession()
    private var isAccessorySessionActive = false
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var writes: Deque<PendingWrite> = []
    /// The write whose frame is on the air. Kept past a deadline that gave up on
    /// it, so the acknowledgement that still arrives is not taken for the next.
    private var inFlight: UUID?

    private static let service = CBUUID(string: AccessoryTransportFrame.serviceUUID)
    private static let notifyCharacteristic = CBUUID(string: AccessoryTransportFrame.notifyCharacteristicUUID)
    private static let writeCharacteristicUUID = CBUUID(string: AccessoryTransportFrame.writeCharacteristicUUID)
    /// Advertised by an unbonded watch and published by every watch; what the
    /// app's AccessorySetupKit declaration names.
    private static let pairingService = CBUUID(string: "0000FED9-0000-1000-8000-00805F9B34FB")

    private override init() {
        super.init()
        accessories.activate(on: .main) { [weak self] event in
            guard event.eventType == .activated else { return }
            MainActor.assumeIsolated {
                self?.isAccessorySessionActive = true
                self?.connectIfPossible()
            }
        }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionDeviceAccessForMedia: true]
        )
    }

    /// Writes the frames `makeFrames` builds for the link they go out on, in
    /// order and each acknowledged, and returns once the last one is. Waits for
    /// a link if there is none yet, for as long as the deadline allows.
    func write(_ makeFrames: @escaping (Connection) throws -> [[UInt8]]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var write = PendingWrite(makeFrames: makeFrames, continuation: continuation)
            let id = write.id
            write.deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.finish(id, with: .failure(LinkError.timedOut))
            }
            writes.append(write)
            writeNext()
        }
    }

    private func connectIfPossible() {
        guard let central, central.state == .poweredOn, isAccessorySessionActive, peripheral == nil else {
            return
        }
        let paired = central.retrievePeripherals(
            withIdentifiers: accessories.accessories.compactMap(\.bluetoothIdentifier)
        )
        let candidate = paired.first { $0.state == .connected }
            ?? paired.first
            ?? central.retrieveConnectedPeripherals(withServices: [Self.pairingService]).first
        guard let candidate else {
            forwardingLog.log("no paired watch yet; scanning")
            central.scanForPeripherals(withServices: [Self.pairingService])
            return
        }
        connect(candidate)
    }

    private func connect(_ candidate: CBPeripheral) {
        peripheral = candidate
        candidate.delegate = self
        central?.connect(candidate)
    }

    private var connection: Connection? {
        guard let peripheral, peripheral.state == .connected, writeCharacteristic != nil else { return nil }
        return Connection(
            peripheralIdentifier: peripheral.identifier,
            maximumWriteLength: peripheral.maximumWriteValueLength(for: .withResponse)
        )
    }

    private func writeNext() {
        guard inFlight == nil, let connection, let peripheral, let writeCharacteristic, !writes.isEmpty else {
            return
        }
        if writes[0].frames == nil {
            do {
                writes[0].frames = try writes[0].makeFrames(connection)
            } catch {
                finish(writes[0].id, with: .failure(error))
                return
            }
        }
        guard let frame = writes[0].frames?.first else {
            finish(writes[0].id, with: .success(()))
            return
        }
        inFlight = writes[0].id
        peripheral.writeValue(Data(frame), for: writeCharacteristic, type: .withResponse)
    }

    private func finish(_ id: UUID, with result: Result<Void, any Error>) {
        guard let index = writes.firstIndex(where: { $0.id == id }) else { return }
        let write = writes.remove(at: index)
        write.deadline?.cancel()
        write.continuation.resume(with: result)
        writeNext()
    }

    private func dropLink() {
        writeCharacteristic = nil
        inFlight = nil
        // A message cut off half way is started over from its first frame on the
        // next link: the watch drops a partial one when it sees FIRST again.
        for index in writes.indices {
            writes[index].frames = nil
        }
    }
}

extension WatchAccessoryLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            dropLink()
            peripheral = nil
            return
        }
        connectIfPossible()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        forwardingLog.error("could not reach the watch: \(String(describing: error), privacy: .public)")
        self.peripheral = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        forwardingLog.log("the watch went away; waiting for it to come back")
        dropLink()
        central.connect(peripheral)
    }
}

extension WatchAccessoryLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            forwardingLog.error("the watch has no forwarding service; its firmware predates it")
            return
        }
        peripheral.discoverCharacteristics([Self.notifyCharacteristic, Self.writeCharacteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        let characteristics = service.characteristics ?? []
        if let notify = characteristics.first(where: { $0.uuid == Self.notifyCharacteristic }) {
            peripheral.setNotifyValue(true, for: notify)
        }
        writeCharacteristic = characteristics.first { $0.uuid == Self.writeCharacteristicUUID }
        writeNext()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        let frame = [UInt8](value)
        if let key = AccessoryTransportFrame.publicKey(from: frame) {
            publicKey = key
        }
        onNotification?(frame)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard let id = inFlight else { return }
        inFlight = nil
        guard let index = writes.firstIndex(where: { $0.id == id }) else {
            writeNext()
            return
        }
        if let error {
            finish(id, with: .failure(LinkError.writeFailed(error.localizedDescription)))
            return
        }
        writes[index].frames?.removeFirst()
        writeNext()
    }
}
#endif
