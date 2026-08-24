import Foundation
import Testing
@testable import API

@Suite
@MainActor
struct APITests {
    @Test func applicationLibraryPersistsUpdatesAndOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "applications.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleApplicationLibrary(fileURL: fileURL)
        let first = PebbleApplication(
            id: try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")),
            shortName: "First",
            longName: "",
            companyName: "Pebble",
            versionCode: 1,
            versionLabel: "1.0",
            capabilities: [],
            targetPlatforms: ["aplite"],
            kind: .watchapp
        )
        var second = first
        second.id = try #require(UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F"))
        second.shortName = "Second"

        _ = try await library.upsert(first)
        _ = try await library.upsert(second)
        _ = try await library.reorder(applicationIDs: [second.id, first.id])

        let reloaded = PebbleApplicationLibrary(fileURL: fileURL)
        #expect(try await reloaded.applications().map(\.id) == [second.id, first.id])
        _ = try await reloaded.remove(applicationID: second.id)
        #expect(try await reloaded.applications() == [first])
    }

    @Test func pbwAppInfoDecodesWatchfaceMetadata() throws {
        let json = Data(#"""
        {
          "uuid": "00112233-4455-6677-8899-aabbccddeeff",
          "shortName": "Orbit",
          "longName": "Orbit Face",
          "companyName": "Pebble",
          "versionCode": 3.5,
          "versionLabel": "3.5",
          "capabilities": ["configurable"],
          "targetPlatforms": ["emery", "basalt"],
          "watchapp": { "watchface": true }
        }
        """#.utf8)

        let application = try PBWApplicationDecoder.decodeAppInfo(from: json)

        #expect(application.displayName == "Orbit Face")
        #expect(application.kind == .watchface)
        #expect(application.bestVariant(for: .pebbleTime2) == "emery")
        #expect(application.bestVariant(for: .pebble2Duo) == nil)
    }

    @Test func legacyPBWDefaultsToApliteAndWatchapp() throws {
        let json = Data(#"""
        {
          "uuid": "00112233-4455-6677-8899-aabbccddeeff",
          "shortName": "Legacy",
          "versionLabel": "1.0"
        }
        """#.utf8)

        let application = try PBWApplicationDecoder.decodeAppInfo(from: json)

        #expect(application.targetPlatforms == ["aplite"])
        #expect(application.kind == .watchapp)
        #expect(application.bestVariant(for: .pebble2Duo) == "aplite")
    }

    @Test func putBytesTransferWaitsForEveryAcknowledgement() throws {
        var session = PutBytesTransferSession(
            bytes: [0x01, 0x02, 0x03],
            objectType: .appExecutable,
            appBankID: 7,
            chunkSize: 2
        )

        #expect(try session.start() == .send(PutBytesCodec.appInitializationFrame(
            objectSize: 3,
            objectType: .appExecutable,
            appBankID: 7
        )))
        let first = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42))
        #expect(first == [.send(try PutBytesCodec.putFrame(cookie: 42, bytes: [0x01, 0x02]))])
        let second = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42))
        #expect(second == [
            .progress(PutBytesTransferProgress(bytesSent: 2, totalBytes: 3)),
            .send(try PutBytesCodec.putFrame(cookie: 42, bytes: [0x03])),
        ])
        let commit = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42))
        #expect(commit == [
            .progress(PutBytesTransferProgress(bytesSent: 3, totalBytes: 3)),
            .send(PutBytesCodec.commitFrame(cookie: 42, crc: PebbleCRC32.calculate([0x01, 0x02, 0x03]))),
        ])
        #expect(try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42)) == [
            .send(PutBytesCodec.installFrame(cookie: 42)),
        ])
        #expect(try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42)) == [.finished])
    }

    @Test func pebbleCRC32MatchesSTMWordAlgorithm() {
        #expect(PebbleCRC32.calculate([0x01, 0x02, 0x03, 0x04]) == 0x1DABE74F)
    }

    @Test func putBytesAppInitializationUsesAppBitAndBigEndianValues() {
        let frame = PutBytesCodec.appInitializationFrame(
            objectSize: 1_000,
            objectType: .appExecutable,
            appBankID: 0x12345678
        )

        #expect(frame == PebbleProtocolFrame(endpoint: 0xBEEF, payload: [
            0x01,
            0x00, 0x00, 0x03, 0xE8,
            0x85,
            0x12, 0x34, 0x56, 0x78,
        ]))
    }

    @Test func putBytesDataAndResponseUseOfficialWireFormat() throws {
        let put = try PutBytesCodec.putFrame(cookie: 0x12345678, bytes: [0xAA, 0xBB])
        #expect(put.payload == [
            0x02,
            0x12, 0x34, 0x56, 0x78,
            0x00, 0x00, 0x00, 0x02,
            0xAA, 0xBB,
        ])

        let response = try PutBytesCodec.decodeResponse(
            PebbleProtocolFrame(endpoint: 0xBEEF, payload: [0x01, 0xCA, 0xFE, 0xBA, 0xBE])
        )
        #expect(response == PutBytesResponse(result: .acknowledgement, cookie: 0xCAFEBABE))
    }

    @Test func appFetchRequestDecodesUUIDAndLittleEndianBankID() throws {
        let frame = PebbleProtocolFrame(endpoint: 6_001, payload: [
            0x01,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
            0x78, 0x56, 0x34, 0x12,
        ])
        let request = try AppFetchCodec.decodeRequest(frame)
        #expect(request.applicationID.uuidString == "00112233-4455-6677-8899-AABBCCDDEEFF")
        #expect(request.appBankID == 0x12345678)
    }

    @Test func appFetchBusyResponseUsesOfficialWireFormat() {
        let frame = AppFetchCodec.responseFrame(status: .busy)
        #expect(frame == PebbleProtocolFrame(endpoint: 6_001, payload: [0x01, 0x02]))
    }

    @Test func appReorderRequestUsesOfficialWireFormat() throws {
        let first = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let second = try #require(UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F"))

        let frame = try AppReorderCodec.frame(applicationIDs: [first, second])

        #expect(frame.endpoint == 0xABCD)
        #expect(frame.payload == [
            0x01, 0x02,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
            0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
            0x98, 0xA9, 0xBA, 0xCB, 0xDC, 0xED, 0xFE, 0x0F,
        ])
    }

    @Test func appReorderResultDecodes() throws {
        let frame = PebbleProtocolFrame(endpoint: 0xABCD, payload: [0x01])
        #expect(try AppReorderCodec.decodeResult(frame) == .success)
    }

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

    @Test
    func watchVersionRequestUsesVersionEndpoint() {
        #expect(WatchVersionCodec.requestFrame() == PebbleProtocolFrame(
            endpoint: 16,
            payload: [0x00]
        ))
    }

    @Test
    func watchVersionResponseDecodesRunningFirmwareAndSerial() throws {
        var payload = [UInt8](repeating: 0, count: 120)
        payload[0] = 0x01
        payload.replaceSubrange(5..<11, with: Array("v5.1.0".utf8))
        payload[46] = 15
        payload.replaceSubrange(108..<120, with: Array("FLINT1234567".utf8))

        let information = try WatchVersionCodec.decode(
            PebbleProtocolFrame(endpoint: 16, payload: payload)
        )

        #expect(information.firmwareVersion == "v5.1.0")
        #expect(information.serialNumber == "FLINT1234567")
        #expect(PebbleWatchModel(hardwarePlatform: information.hardwarePlatform) == .pebble2Duo)
    }

    @Test
    func batteryLevelCodecAcceptsBluetoothPercentage() {
        #expect(BatteryLevelCodec.decode([84]) == 84)
        #expect(BatteryLevelCodec.decode([100]) == 100)
        #expect(BatteryLevelCodec.decode([]) == nil)
        #expect(BatteryLevelCodec.decode([101]) == nil)
    }

    @Test
    func timeSynchronizationEncodesUTCAndTimeZone() throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let frame = try TimeSynchronizationCodec.frame(date: date, timeZone: timeZone)

        #expect(frame.endpoint == 11)
        #expect(frame.payload == [
            0x03,
            0x65, 0x53, 0xF1, 0x00,
            0x02, 0x1C,
            0x0A,
        ] + Array("Asia/Tokyo".utf8))
    }

    @Test
    func timeSynchronizationRoundsToNearestSecond() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 1.6)

        let frame = try TimeSynchronizationCodec.frame(date: date, timeZone: timeZone)

        #expect(Array(frame.payload[1...4]) == [0x00, 0x00, 0x00, 0x02])
    }

    @Test
    func pingPongCodecRoundTripsCookie() throws {
        let ping = PingPongMessage.ping(cookie: 0x1234_ABCD)
        let frame = PingPongCodec.frame(for: ping)

        #expect(frame.endpoint == 2_001)
        #expect(frame.payload == [0x00, 0x12, 0x34, 0xAB, 0xCD])
        #expect(try PingPongCodec.decode(frame) == ping)
    }

    @Test
    func pingPongCodecDecodesPong() throws {
        let frame = PebbleProtocolFrame(
            endpoint: 2_001,
            payload: [0x01, 0x00, 0x00, 0x00, 0x2A]
        )

        #expect(try PingPongCodec.decode(frame) == .pong(cookie: 42))
    }
}
