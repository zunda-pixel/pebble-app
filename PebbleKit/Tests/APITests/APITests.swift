import Testing
@testable import API

@Suite
@MainActor
struct APITests {
    @Test
    func supportedModelsUseProtocolCodenames() {
        #expect(PebbleWatchModel.pebble2Duo.rawValue == "FLINT")
        #expect(PebbleWatchModel.pebbleTime2.rawValue == "EMERY")
        #expect(PebbleWatchModel.pebbleRound2.rawValue == "GABBRO")
    }

    @Test
    func mockClientDiscoversOnlySupportedModels() async throws {
        let client = MockPebbleClient()
        let devices = try await client.scan()

        #expect(devices.count == PebbleWatchModel.allCases.count)
        #expect(Set(devices.map(\.model)) == Set(PebbleWatchModel.allCases))
    }

    @Test
    func mockClientConnectsToDiscoveredDevice() async throws {
        let client = MockPebbleClient()
        let discoveredDevice = try #require(await client.scan().first)
        let connectedDevice = try await client.connect(to: discoveredDevice)

        #expect(connectedDevice.id == discoveredDevice.id)
        #expect(connectedDevice.model == discoveredDevice.model)
        #expect(connectedDevice.batteryLevel == 84)
    }

    @Test
    func ppogVersionOneResetRequestEncoding() throws {
        let packet = PPoGPacket.resetRequest(sequence: 0, version: .one)

        #expect(try packet.encoded(for: .one) == [0x02, 0x01])
    }

    @Test
    func ppogResetCompleteNegotiatesWindows() throws {
        let packet = PPoGPacket.resetComplete(
            sequence: 0,
            receiveWindow: 25,
            transmitWindow: 20
        )
        let encoded = try packet.encoded(for: .one)

        #expect(encoded == [0x03, 25, 20])
        #expect(try PPoGPacket(decoding: encoded) == packet)
    }

    @Test
    func ppogRejectsInvalidSequence() {
        let packet = PPoGPacket.acknowledgement(sequence: 32)

        #expect(throws: PPoGPacketError.invalidSequence) {
            try packet.encoded(for: .one)
        }
    }

    @Test
    func ppogSessionHonorsTransmitWindow() throws {
        var session = PPoGSession(receiveWindow: 2, transmitWindow: 2)
        let initialActions = try session.enqueue(
            Array(0..<10),
            maximumPacketSize: 4
        )

        #expect(initialActions == [
            .send(.data(sequence: 0, payload: [0, 1, 2])),
            .send(.data(sequence: 1, payload: [3, 4, 5])),
        ])

        let nextActions = try session.receive(.acknowledgement(sequence: 0))
        #expect(nextActions == [
            .send(.data(sequence: 2, payload: [6, 7, 8])),
        ])
    }

    @Test
    func ppogSessionAcknowledgesOrderedInboundData() throws {
        var session = PPoGSession()

        let actions = try session.receive(.data(sequence: 0, payload: [1, 2, 3]))

        #expect(actions == [
            .deliver([1, 2, 3]),
            .send(.acknowledgement(sequence: 0)),
        ])
    }

    @Test
    func pebbleProtocolFrameRoundTripsFragmentedInput() throws {
        let frame = PebbleProtocolFrame(endpoint: 2_001, payload: [0x00, 0x00, 0x00, 0x2A])
        let bytes = try frame.encoded()
        var decoder = PebbleProtocolFrameDecoder()

        #expect(try decoder.append(Array(bytes.prefix(3))).isEmpty)
        #expect(try decoder.append(Array(bytes.dropFirst(3))) == [frame])
    }

    @Test
    func pebbleProtocolDecoderEmitsMultipleFrames() throws {
        let first = PebbleProtocolFrame(endpoint: 16, payload: [0x00])
        let second = PebbleProtocolFrame(endpoint: 18, payload: [0x01, 0x02])
        var decoder = PebbleProtocolFrameDecoder()

        let frames = try decoder.append(first.encoded() + second.encoded())

        #expect(frames == [first, second])
    }
}
