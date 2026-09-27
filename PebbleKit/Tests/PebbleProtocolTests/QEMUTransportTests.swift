#if os(macOS)
import Foundation
import Network
import PebbleProtocol
import Synchronization
import Testing
@testable import PebbleTransport

/// The emulator's side of the socket, driven through the same framing the
/// real one uses, so the transport can be held to what it says back without
/// an emulator running.
@Suite
@MainActor
struct QEMUTransportTests {
    @Test func theEmulatorAskingForTheTimeIsAnsweredWithIt() async throws {
        let emulator = try FakeEmulator()
        let client = QEMUWatchClient(host: "127.0.0.1", port: try await emulator.start())
        let watch = try await client.connect(to: try #require(try await client.scan().first))
        let before = emulator.received(on: TimeSynchronizationCodec.endpoint).count

        // What `clock_request_time_from_phone` sends when the reader turns
        // the time source back to automatic.
        emulator.send(PebbleProtocolFrame(endpoint: TimeSynchronizationCodec.endpoint, payload: [0x04]))
        let answers = try await emulator.waitFor(on: TimeSynchronizationCodec.endpoint, count: before + 1)

        #expect(answers.last?.payload.first == 0x03)
        await client.disconnect(from: watch)
        emulator.stop()
    }

    /// The emulator asks at boot, before anything is listening, and never
    /// again; without being told, it runs on capabilities that refuse the
    /// weather and never sync a setting.
    @Test func theEmulatorIsToldThePhonesCapabilitiesWithoutAsking() async throws {
        let emulator = try FakeEmulator()
        let client = QEMUWatchClient(host: "127.0.0.1", port: try await emulator.start())
        let watch = try await client.connect(to: try #require(try await client.scan().first))

        let told = try await emulator.waitFor(on: PhoneVersionCodec.endpoint, count: 1)

        #expect(told.first == PhoneVersionCodec.responseFrame(operatingSystem: .macOS))
        await client.disconnect(from: watch)
        emulator.stop()
    }
}

private final class FakeEmulator: @unchecked Sendable {
    private struct State {
        var connection: NWConnection?
        var buffer: [UInt8] = []
        var decoder = PebbleProtocolFrameDecoder()
        var received: [PebbleProtocolFrame] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-emulator")
    private let state = Mutex(State())

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            state.withLock { $0.connection = connection }
            connection.start(queue: queue)
            receive(on: connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { [listener] state in
                let port: UInt16?
                switch state {
                case .ready: port = listener.port?.rawValue
                case .failed: port = nil
                default: return
                }
                let alreadyAnswered = resumed.withLock { answered in
                    defer { answered = true }
                    return answered
                }
                guard !alreadyAnswered else { return }
                if let port {
                    continuation.resume(returning: port)
                } else {
                    continuation.resume(throwing: WatchConnectionError.disconnected)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        state.withLock { $0.connection?.cancel() }
        listener.cancel()
    }

    func received(on endpoint: UInt16) -> [PebbleProtocolFrame] {
        state.withLock { $0.received.filter { $0.endpoint == endpoint } }
    }

    func waitFor(on endpoint: UInt16, count: Int) async throws -> [PebbleProtocolFrame] {
        for _ in 0..<400 {
            let frames = received(on: endpoint)
            if frames.count >= count { return frames }
            try await Task.sleep(for: .milliseconds(5))
        }
        return received(on: endpoint)
    }

    func send(_ frame: PebbleProtocolFrame) {
        guard let bytes = try? frame.encoded(),
              let connection = state.withLock({ $0.connection }) else { return }
        var packet: [UInt8] = [0xFE, 0xED, 0x00, 0x01, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]
        packet += bytes
        packet += [0xBE, 0xEF]
        connection.send(content: Data(packet), completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            if let data { consume([UInt8](data)) }
            guard error == nil, !complete else { return }
            receive(on: connection)
        }
    }

    private func consume(_ bytes: [UInt8]) {
        let frames: [PebbleProtocolFrame] = state.withLock { state in
            state.buffer += bytes
            var frames: [PebbleProtocolFrame] = []
            while state.buffer.count >= 8 {
                let length = Int(state.buffer[4]) << 8 | Int(state.buffer[5])
                guard state.buffer.count >= 8 + length else { break }
                let payload = Array(state.buffer[6..<(6 + length)])
                state.buffer.removeFirst(8 + length)
                frames += state.decoder.append(payload).frames
            }
            state.received += frames
            return frames
        }
        for frame in frames where frame == WatchVersionCodec.requestFrame() {
            // The shortest version answer `WatchVersionCodec` reads.
            var payload = [UInt8](repeating: 0, count: 120)
            payload[0] = 0x01
            send(PebbleProtocolFrame(endpoint: WatchVersionCodec.endpoint, payload: payload))
        }
    }
}
#endif
