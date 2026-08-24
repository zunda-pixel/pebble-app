import Foundation
import Testing
@testable import API

@Suite
@MainActor
struct APITests {
    @Test func appMessagePushRoundTripsEveryTupleType() throws {
        let applicationID = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let message = AppMessageData(
            transactionID: 7,
            applicationID: applicationID,
            tuples: [
                AppMessageTuple(key: 1, value: .bytes([0xAA, 0xBB])),
                AppMessageTuple(key: 2, value: .string("Pebble")),
                AppMessageTuple(key: 3, value: .unsigned(0x12345678)),
                AppMessageTuple(key: 4, value: .signed(-42)),
            ]
        )

        let frame = try AppMessageCodec.pushFrame(message)

        #expect(frame.endpoint == 48)
        #expect(frame.payload[0..<2] == [0x01, 7])
        #expect(try AppMessageCodec.decode(frame) == .push(message))
    }

    @Test func appMessageUsesOfficialTupleWireFormat() throws {
        let applicationID = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let frame = try AppMessageCodec.pushFrame(AppMessageData(
            transactionID: 0x12,
            applicationID: applicationID,
            tuples: [AppMessageTuple(key: 0x12345678, value: .string("Hi"))]
        ))

        #expect(Array(frame.payload.prefix(19)) == [
            0x01, 0x12,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
            0x01,
        ])
        #expect(Array(frame.payload.dropFirst(19)) == [
            0x78, 0x56, 0x34, 0x12, 0x01, 0x03, 0x00, 0x48, 0x69, 0x00,
        ])
    }

    @Test func appMessageACKAndNACKRoundTrip() throws {
        let ack = AppMessageCodec.resultFrame(transactionID: 9, acknowledged: true)
        let nack = AppMessageCodec.resultFrame(transactionID: 10, acknowledged: false)

        #expect(ack.payload == [0xFF, 9])
        #expect(nack.payload == [0x7F, 10])
        #expect(try AppMessageCodec.decode(ack) == .acknowledgement(transactionID: 9))
        #expect(try AppMessageCodec.decode(nack) == .negativeAcknowledgement(transactionID: 10))
    }

    @Test func pbwBinaryHeaderProvidesBlobDBMetadata() throws {
        var bytes = [UInt8](repeating: 0, count: PBWBinaryHeaderDecoder.size)
        bytes.replaceSubrange(0..<8, with: [0x50, 0x42, 0x4C, 0x41, 0x50, 0x50, 0, 0])
        bytes.replaceSubrange(8..<14, with: [1, 0, 4, 2, 3, 7])
        bytes.replaceSubrange(88..<92, with: [0x78, 0x56, 0x34, 0x12])
        bytes.replaceSubrange(96..<100, with: [0xEF, 0xCD, 0xAB, 0x90])
        bytes.replaceSubrange(104..<120, with: [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])

        let header = try PBWBinaryHeaderDecoder.decode(from: Data(bytes))
        let metadata = header.appMetadata(name: "Orbit")

        #expect(header.headerVersionMajor == 1)
        #expect(header.sdkVersionMajor == 4)
        #expect(header.sdkVersionMinor == 2)
        #expect(header.appVersionMajor == 3)
        #expect(header.appVersionMinor == 7)
        #expect(header.iconResourceID == 0x12345678)
        #expect(header.flags == 0x90ABCDEF)
        #expect(metadata.applicationID.uuidString == "00112233-4455-6677-8899-AABBCCDDEEFF")
        #expect(metadata.name == "Orbit")
    }

    @Test func pbwBinaryHeaderRejectsInvalidInput() {
        #expect(throws: PBWBinaryHeaderError.invalidSize) {
            try PBWBinaryHeaderDecoder.decode(from: Data())
        }
        #expect(throws: PBWBinaryHeaderError.invalidSentinel) {
            try PBWBinaryHeaderDecoder.decode(from: Data(repeating: 0, count: PBWBinaryHeaderDecoder.size))
        }
    }

    @Test func blobDBApplicationMetadataUsesPebbleWireLayout() throws {
        let applicationID = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let metadata = PebbleAppMetadata(
            applicationID: applicationID,
            flags: 0x12345678,
            iconResourceID: 0x90ABCDEF,
            appVersionMajor: 3,
            appVersionMinor: 5,
            sdkVersionMajor: 4,
            sdkVersionMinor: 1,
            name: "Orbit"
        )

        let bytes = metadata.encoded()

        #expect(bytes.count == 126)
        #expect(Array(bytes[0..<16]) == [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])
        #expect(Array(bytes[16..<24]) == [0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB, 0x90])
        #expect(Array(bytes[24..<30]) == [3, 5, 4, 1, 0, 0])
        #expect(Array(bytes[30..<36]) == Array("Orbit".utf8) + [0])
        #expect(bytes[125] == 0)
    }

    @Test func blobDBBuildsApplicationInsertAndDeleteFrames() throws {
        let applicationID = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let metadata = PebbleAppMetadata(
            applicationID: applicationID,
            flags: 0,
            iconResourceID: 0,
            appVersionMajor: 1,
            appVersionMinor: 0,
            sdkVersionMajor: 4,
            sdkVersionMinor: 0,
            name: "App"
        )

        let insert = BlobDBCodec.insertApplicationFrame(metadata: metadata, token: 0x1234)
        let delete = BlobDBCodec.deleteApplicationFrame(applicationID: applicationID, token: 0xABCD)

        #expect(insert.endpoint == 0xB1DB)
        #expect(Array(insert.payload.prefix(21)) == [
            0x01, 0x12, 0x34, 0x02, 0x10,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])
        #expect(Array(insert.payload[21..<23]) == [0x7E, 0x00])
        #expect(delete.payload == [
            0x04, 0xAB, 0xCD, 0x02, 0x10,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])
    }

    @Test func blobDBDecodesResponseAndPreservesUTF8NameBoundary() throws {
        let response = try BlobDBCodec.decodeResponse(PebbleProtocolFrame(
            endpoint: BlobDBCodec.endpoint,
            payload: [0x12, 0x34, 0x0B]
        ))
        let metadata = PebbleAppMetadata(
            applicationID: UUID(),
            flags: 0,
            iconResourceID: 0,
            appVersionMajor: 1,
            appVersionMinor: 0,
            sdkVersionMajor: 4,
            sdkVersionMinor: 0,
            name: String(repeating: "石", count: 40)
        )
        let nameBytes = Array(metadata.encoded()[30..<126])
        let terminator = try #require(nameBytes.firstIndex(of: 0))

        #expect(response == BlobDBResponse(token: 0x1234, status: .tryLater))
        #expect(String(bytes: nameBytes[..<terminator], encoding: .utf8) != nil)
        #expect(terminator <= 95)
    }

    @Test func invalidPBWArchiveIsRejected() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).pbw")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("not a zip archive".utf8).write(to: fileURL)

        #expect(throws: (any Error).self) {
            try PBWPackageImporter.load(from: fileURL, for: .pebbleTime2)
        }
    }

    @Test func pbwManifestSelectsBestVariantAndTransferOrder() throws {
        let basalt = Data(#"""
        {
          "application": { "name": "app.bin", "size": 12 },
          "resources": { "name": "app.pbpack", "size": 8 }
        }
        """#.utf8)
        let emery = Data(#"""
        {
          "application": {
            "crc": 305419896,
            "name": "app.bin",
            "sdk_version": { "major": 4, "minor": 0 },
            "size": 24
          },
          "resources": { "name": "app.pbpack", "size": 16 },
          "worker": { "name": "worker.bin", "size": 4 }
        }
        """#.utf8)

        let plan = try PBWManifestDecoder.installationPlan(
            for: .pebbleTime2,
            manifestsByVariant: ["basalt": basalt, "emery": emery]
        )

        #expect(plan.variant == "emery")
        #expect(plan.objects.map(\.objectType) == [.appExecutable, .appResource, .worker])
        #expect(plan.objects.map(\.blob.name) == ["app.bin", "app.pbpack", "worker.bin"])
    }

    @Test func pbwManifestRejectsUnsupportedWatchVariant() {
        let chalk = Data(#"""
        { "application": { "name": "app.bin", "size": 12 } }
        """#.utf8)

        #expect(throws: PBWManifestError.noCompatibleVariant) {
            try PBWManifestDecoder.installationPlan(
                for: .pebble2Duo,
                manifestsByVariant: ["chalk": chalk]
            )
        }
    }

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

    @Test func applicationLibrarySnapshotRestoresMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "applications.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleApplicationLibrary(fileURL: fileURL)
        let application = PebbleApplication(
            id: try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")),
            shortName: "Original",
            longName: "",
            companyName: "Pebble",
            versionCode: 1,
            versionLabel: "1.0",
            capabilities: [],
            targetPlatforms: ["aplite"],
            kind: .watchapp
        )
        _ = try await library.upsert(application)
        let snapshot = try await library.snapshot(applicationID: application.id)
        var updated = application
        updated.shortName = "Updated"
        updated.versionLabel = "2.0"
        _ = try await library.upsert(updated)

        let restored = try await library.restore(snapshot)

        #expect(restored == [application])
        #expect(try await library.applications() == [application])
    }

    @Test func applicationLibraryPersistsPerWatchSynchronizationState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "applications.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = UUID()
        let secondID = UUID()
        let library = PebbleApplicationLibrary(fileURL: fileURL)

        try await library.setSynchronizedApplicationIDs([firstID, secondID], deviceID: "watch-a")
        try await library.setSynchronizedApplicationIDs([secondID], deviceID: "watch-b")
        let reloaded = PebbleApplicationLibrary(fileURL: fileURL)

        #expect(try await reloaded.synchronizedApplicationIDs(deviceID: "watch-a") == [firstID, secondID])
        #expect(try await reloaded.synchronizedApplicationIDs(deviceID: "watch-b") == [secondID])
        #expect(try await reloaded.synchronizedApplicationIDs(deviceID: "unknown") == [])
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

    @Test
    func mockClientRecordsAppMessagesAndResponses() async throws {
        let client = MockPebbleClient()
        let applicationID = UUID()
        let tuples = [AppMessageTuple(key: 7, value: .string("value"))]

        try await client.sendAppMessage(applicationID: applicationID, tuples: tuples)
        try await client.respondToAppMessage(transactionID: 9, acknowledged: true)

        #expect(client.sentAppMessages.count == 1)
        #expect(client.sentAppMessages.first?.applicationID == applicationID)
        #expect(client.sentAppMessages.first?.tuples == tuples)
        #expect(client.appMessageResponses.first?.transactionID == 9)
        #expect(client.appMessageResponses.first?.acknowledged == true)
    }

    @Test
    func diagnosticsKeepsBoundedHistoryAndExportsReport() async throws {
        let diagnostics = PebbleDiagnostics(maximumEntryCount: 2)
        await diagnostics.record(category: "test", message: "first")
        await diagnostics.record(.warning, category: "test", message: "second")
        await diagnostics.record(.error, category: "test", message: "third")

        let entries = await diagnostics.snapshot()
        #expect(entries.map(\.message) == ["second", "third"])

        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = try await diagnostics.exportReport(
            device: nil,
            applications: [],
            directory: directory
        )
        #expect(FileManager.default.fileExists(atPath: reportURL.path))
        #expect(try Data(contentsOf: reportURL).isEmpty == false)
    }

    @Test
    func applicationLibraryMetadataDecodesOlderSnapshots() throws {
        let id = UUID()
        let data = Data("""
        [{"id":"\(id.uuidString)","shortName":"Old","longName":"","companyName":"",\
        "versionLabel":"1.0","capabilities":[],"targetPlatforms":["aplite"],"kind":"watchapp"}]
        """.utf8)

        let application = try #require(JSONDecoder().decode([PebbleApplication].self, from: data).first)

        #expect(application.appKeys.isEmpty)
        #expect(application.hasCompanionJavaScript == false)
        #expect(application.isConfigurable == false)
    }

    @Test
    func timelineNotificationUsesOfficialBlobDBLayout() throws {
        let itemID = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let parentID = try #require(UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100"))
        let notification = PebbleTimelineNotification(
            id: itemID,
            parentApplicationID: parentID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Title",
            body: "Body",
            appName: "App"
        )

        let frame = try TimelineNotificationCodec.insertFrame(notification, token: 0x1234)

        #expect(frame.endpoint == 0xB1DB)
        #expect(Array(frame.payload.prefix(5)) == [0x01, 0x12, 0x34, 0x04, 0x10])
        #expect(Array(frame.payload[5..<21]) == [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])
        let value = try notification.encoded()
        #expect(Array(frame.payload.dropFirst(23)) == value)
        #expect(Array(value[32..<46]) == [
            0x00, 0xF1, 0x53, 0x65,
            0x00, 0x00,
            0x01,
            0x00, 0x00,
            0x04,
            0x15, 0x00,
            0x03,
            0x00,
        ])
        #expect(Array(value.dropFirst(46)) == [
            0x01, 0x05, 0x00, 0x54, 0x69, 0x74, 0x6C, 0x65,
            0x03, 0x04, 0x00, 0x42, 0x6F, 0x64, 0x79,
            0x1E, 0x03, 0x00, 0x41, 0x70, 0x70,
        ])
    }

    @Test
    func timelineNotificationTrimsTextWithoutSplittingUTF8() throws {
        let notification = PebbleTimelineNotification(
            parentApplicationID: UUID(),
            title: String(repeating: "石", count: 30),
            body: "Body"
        )

        let value = try notification.encoded()
        let titleLength = Int(value[47]) | Int(value[48]) << 8
        let titleBytes = Array(value[49..<(49 + titleLength)])

        #expect(titleLength == 63)
        #expect(String(bytes: titleBytes, encoding: .utf8) != nil)
    }

    @Test
    func mockClientRecordsTimelineNotifications() async throws {
        let client = MockPebbleClient()
        let notification = PebbleTimelineNotification(
            parentApplicationID: UUID(),
            title: "Title",
            body: "Body"
        )

        try await client.sendNotification(notification)

        #expect(client.sentNotifications == [notification])
    }
}

@Suite
struct PebbleWatchLibraryTests {
    @Test func recordsUpdatesPreferencesAndForgetsWatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "watches.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleWatchLibrary(fileURL: fileURL)
        let device = PebbleDevice(
            id: "watch-1",
            name: "Pebble QEMU",
            model: .pebbleTime2,
            firmwareVersion: "v1",
            batteryLevel: 75,
            serialNumber: "SERIAL"
        )

        var watches = try await library.record(device)
        #expect(watches.count == 1)
        #expect(watches[0].automaticallyConnects)
        #expect(watches[0].lastBatteryLevel == 75)

        watches = try await library.setAutomaticallyConnects(false, watchID: device.id)
        #expect(!watches[0].automaticallyConnects)

        let reloaded = PebbleWatchLibrary(fileURL: fileURL)
        #expect(try await reloaded.allWatches()[0].firmwareVersion == "v1")
        #expect(try await reloaded.remove(watchID: device.id).isEmpty)
    }
}

@Suite
struct CompanionDataTests {
    @Test func firmwareUsesSystemPutBytesAndSystemMessages() throws {
        var session = PutBytesTransferSession(bytes: [1, 2, 3], objectType: .firmware, appBankID: 1)
        guard case .send(let initialization) = try session.start() else {
            Issue.record("Expected firmware initialization frame")
            return
        }
        #expect(initialization.payload == [0x01, 0, 0, 0, 3, PutBytesObjectType.firmware.rawValue, 1])
        #expect(SystemMessageCodec.firmwareUpdateStartFrame(bytesToSend: 3).payload == [0, 1, 0, 0, 0, 0, 3, 0, 0, 0])
        #expect(SystemMessageCodec.firmwareUpdateCompleteFrame().payload == [0, 2])
    }

    @Test func healthSyncUsesOfficialEndpointAndLittleEndianTimestamp() {
        let frame = HealthSyncCodec.requestFrame(since: Date(timeIntervalSince1970: 0x12345678))
        #expect(frame.endpoint == 911)
        #expect(frame.payload == [0x01, 0x78, 0x56, 0x34, 0x12])
    }

    @Test func timelinePinEncodesPinTypeAndGenericLayout() throws {
        let pin = PebbleTimelinePin(
            id: UUID(),
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 100),
            title: "Meeting",
            subtitle: nil,
            body: nil
        )
        let bytes = try pin.encoded()
        #expect(bytes[38] == 0x02)
        #expect(bytes[41] == 0x01)
        #expect(TimelinePinCodec.insertFrame(pin, token: 1).endpoint == BlobDBCodec.endpoint)
    }

    @Test func healthLibraryPersistsSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "health.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleHealthLibrary(fileURL: url)
        let sample = PebbleHealthSample(date: Date(timeIntervalSince1970: 10), steps: 1234, sleepMinutes: 420)
        try await library.save([sample])
        #expect(try await library.samples() == [sample])
    }
}
