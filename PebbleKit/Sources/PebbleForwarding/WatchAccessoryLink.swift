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

    /// Every notification the watch sends on the service, and the public key it
    /// answers a read with.
    var onNotification: ((_ frame: [UInt8]) -> Void)?
    /// What the watch last said its public key is. It keeps the key across
    /// reboots and notifies it only when a subscription starts, so a session
    /// that starts on a link another process already subscribed would otherwise
    /// never hear it; the read in `didDiscoverCharacteristicsFor` asks for it.
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
    /// Every paired watch asked for at once, until one answers. Waiting on the
    /// first of two paired watches waited for ever when that one was away.
    private var candidates: [CBPeripheral] = []
    private var writeCharacteristic: CBCharacteristic?
    private var writes: Deque<PendingWrite> = []
    /// The write whose frame is on the air. Kept past a deadline that gave up on
    /// it, so the acknowledgement that still arrives is not taken for the next.
    private var inFlight: UUID?
    /// Connects that failed since the link last worked. Past a handful the
    /// link stops trying by itself and waits for the next write to ask again.
    private var failures = 0
    private var retry: Task<Void, Never>?

    private static let maximumFailures = 5
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
            connectIfPossible()
            writeNext()
        }
    }

    private func connectIfPossible() {
        guard let central, central.state == .poweredOn, isAccessorySessionActive,
              peripheral == nil, candidates.isEmpty else {
            return
        }
        retry?.cancel()
        retry = nil
        let paired = central.retrievePeripherals(
            withIdentifiers: accessories.accessories.compactMap(\.bluetoothIdentifier)
        )
        let chosen = paired.first { $0.state == .connected }.map { [$0] }
            ?? (paired.isEmpty ? central.retrieveConnectedPeripherals(withServices: [Self.pairingService]) : paired)
        guard !chosen.isEmpty else {
            forwardingLog.log("no paired watch yet; scanning")
            central.scanForPeripherals(withServices: [Self.pairingService])
            return
        }
        for candidate in chosen {
            attempt(candidate)
        }
    }

    private func attempt(_ candidate: CBPeripheral) {
        guard !candidates.contains(candidate) else { return }
        candidates.append(candidate)
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

    /// Tries again after a pause, a bounded number of times: a watch that is
    /// away fails every connect at once, and retrying without a pause or an
    /// end would spin.
    private func retryAfterFailure() {
        failures += 1
        guard failures < Self.maximumFailures else {
            forwardingLog.error("the watch could not be reached \(self.failures) times; waiting for the next write")
            return
        }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.connectIfPossible()
        }
    }
}

extension WatchAccessoryLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            dropLink()
            peripheral = nil
            candidates = []
            retry?.cancel()
            retry = nil
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
        attempt(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if self.peripheral == nil, candidates.contains(peripheral) {
            self.peripheral = peripheral
            for other in candidates where other != peripheral {
                central.cancelPeripheralConnection(other)
            }
            candidates = []
        }
        guard peripheral == self.peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        forwardingLog.error("could not reach the watch: \(String(describing: error), privacy: .public)")
        candidates.removeAll { $0 == peripheral }
        if peripheral == self.peripheral {
            dropLink()
            self.peripheral = nil
        }
        guard self.peripheral == nil, candidates.isEmpty else { return }
        retryAfterFailure()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        guard peripheral == self.peripheral else { return }
        forwardingLog.log("the watch went away; waiting for it to come back")
        dropLink()
        central.connect(peripheral)
    }
}

extension WatchAccessoryLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            // `didModifyServices` looks again if the watch publishes it later.
            forwardingLog.error("the watch has no forwarding service; its firmware predates it")
            return
        }
        peripheral.discoverCharacteristics([Self.notifyCharacteristic, Self.writeCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral == self.peripheral,
              writeCharacteristic == nil || invalidatedServices.contains(where: { $0.uuid == Self.service }) else {
            return
        }
        forwardingLog.log("the watch changed its services; looking for the forwarding service again")
        dropLink()
        peripheral.discoverServices([Self.service])
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        let characteristics = service.characteristics ?? []
        if let notify = characteristics.first(where: { $0.uuid == Self.notifyCharacteristic }) {
            peripheral.setNotifyValue(true, for: notify)
            // Another process subscribed first has already had the key, and the
            // watch notifies it only on a subscription that starts. Older
            // firmware refuses the read, which `didUpdateValueFor` ignores.
            if publicKey == nil {
                peripheral.readValue(for: notify)
            }
        }
        writeCharacteristic = characteristics.first { $0.uuid == Self.writeCharacteristicUUID }
        if writeCharacteristic != nil {
            failures = 0
        }
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
