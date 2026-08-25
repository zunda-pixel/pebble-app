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
            body: "Body",
            appName: nil
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
            body: "Body",
            appName: nil
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
    @Test func firmwareStartResponseAndTimelineActionRoundTrip() throws {
        #expect(try SystemMessageCodec.decodeFirmwareUpdateStartResponse(PebbleProtocolFrame(
            endpoint: SystemMessageCodec.endpoint, payload: [0, 0x0A, 1]
        )))
        let id = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let invocation = try TimelineActionCodec.decode(PebbleProtocolFrame(
            endpoint: TimelineActionCodec.endpoint,
            payload: [0x02] + BlobDBCodec.uuidBytes(id) + [7, 0]
        ))
        #expect(invocation == TimelineActionInvocation(itemID: id, actionID: 7))
        #expect(TimelineActionCodec.responseFrame(itemID: id, succeeded: true).payload.last == 0)
    }

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

    @Test func healthSyncUsesOfficialEndpointAndLittleEndianElapsedTime() {
        let frame = HealthSyncCodec.requestFrame(
            since: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 0x12345678 + 100)
        )
        #expect(frame.endpoint == 911)
        #expect(frame.payload == [0x01, 0x78, 0x56, 0x34, 0x12])
    }

    @Test func fullHealthSyncUsesMaximumElapsedTime() {
        #expect(HealthSyncCodec.requestFrame(since: nil).payload == [0x01, 0xff, 0xff, 0xff, 0xff])
    }

    @Test func healthDataLoggingDecodesStepSessionAndAcknowledgesPackets() throws {
        var processor = HealthDataLoggingProcessor()
        let openPayload: [UInt8] = [0x01, 7] + Array(repeating: 0, count: 16)
            + [0, 0, 0, 0] + [81, 0, 0, 0] + [0, 15, 0]
        let open = try processor.process(PebbleProtocolFrame(endpoint: 6_778, payload: openPayload))
        #expect(open.response?.payload == [0x85, 7])

        let item: [UInt8] = [5, 0, 100, 0, 0, 0, 0, 6, 1, 42, 0, 0, 0, 0, 0]
        let sendPayload: [UInt8] = [0x02, 7] + Array(repeating: 0, count: 8) + item
        let result = try processor.process(PebbleProtocolFrame(endpoint: 6_778, payload: sendPayload))
        #expect(result.response?.payload == [0x85, 7])
        #expect(result.samples.count == 1)
        #expect(result.samples[0].steps == 42)
    }

    @Test func unknownHealthDataLoggingSessionIsRejected() throws {
        var processor = HealthDataLoggingProcessor()
        let payload: [UInt8] = [0x02, 9] + Array(repeating: 0, count: 8)
        let result = try processor.process(PebbleProtocolFrame(endpoint: 6_778, payload: payload))
        #expect(result.response?.payload == [0x86, 9])
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
        #expect(try TimelinePinCodec.insertFrame(pin, token: 1).endpoint == BlobDBCodec.endpoint)
    }

    @Test func healthLibraryPersistsSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "health.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleHealthLibrary(fileURL: url)
        let sample = PebbleHealthSample(
            date: Date(timeIntervalSince1970: 10), steps: 1234, sleepMinutes: 420,
            timeZoneIdentifier: "UTC", updatedAt: Date(timeIntervalSince1970: 20)
        )
        try await library.save([sample])
        #expect(try await library.samples() == [sample])
        let replacement = PebbleHealthSample(
            date: sample.date, steps: 2000, sleepMinutes: 400,
            timeZoneIdentifier: "UTC", updatedAt: Date(timeIntervalSince1970: 30)
        )
        let merged = try await library.merge([replacement])
        #expect(merged.count == 1)
        #expect(merged[0].steps == 2000)
        #expect(merged[0].sleepMinutes == 400)
        #expect(merged[0].date == Date(timeIntervalSince1970: 0))
    }

    @Test func healthMergeKeepsHighestStepsAndLatestSleep() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "health.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleHealthLibrary(fileURL: url)
        let watch = PebbleHealthSample(
            date: Date(timeIntervalSince1970: 100), steps: 8_000, sleepMinutes: 300,
            timeZoneIdentifier: "UTC", updatedAt: Date(timeIntervalSince1970: 200)
        )
        let imported = PebbleHealthSample(
            date: Date(timeIntervalSince1970: 200), steps: 7_000, sleepMinutes: 450,
            timeZoneIdentifier: "UTC", source: .imported, updatedAt: Date(timeIntervalSince1970: 300)
        )
        let merged = try await library.merge([watch, imported])
        #expect(merged.count == 1)
        #expect(merged[0].steps == 8_000)
        #expect(merged[0].sleepMinutes == 450)
        #expect(merged[0].source == .imported)
    }

    @Test func healthArchiveRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sourceURL = directory.appending(path: "source.json")
        let destinationURL = directory.appending(path: "destination.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = PebbleHealthLibrary(fileURL: sourceURL)
        try await source.save([PebbleHealthSample(date: .now, steps: 123, sleepMinutes: 45)])
        let archiveURL = try await source.export()
        let destination = PebbleHealthLibrary(fileURL: destinationURL)
        let imported = try await destination.importArchive(from: archiveURL)
        #expect(imported.count == 1)
        #expect(imported[0].steps == 123)
        #expect(imported[0].source == .imported)
    }

    @Test func appRunStateUsesOfficialEndpointAndUUIDPayload() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let frame = AppRunStateCodec.startFrame(applicationID: id)
        #expect(frame.endpoint == 52)
        #expect(frame.payload == [0x01, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        #expect(try AppRunStateCodec.decode(frame) == .started(id))
        #expect(AppRunStateCodec.requestFrame().payload == [0x03])
    }

    @Test func notificationPreferencesApplyMuteAndOvernightQuietHours() {
        let id = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tenPM = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 22))!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let quiet = NotificationDeliveryPreferences(quietHoursEnabled: true, quietHoursStart: 21, quietHoursEnd: 7)
        #expect(!quiet.permits(applicationID: id, at: tenPM, calendar: calendar))
        #expect(quiet.permits(applicationID: id, at: noon, calendar: calendar))
        let muted = NotificationDeliveryPreferences(mutedApplicationIDs: [id])
        #expect(!muted.permits(applicationID: id, at: noon, calendar: calendar))
    }

    @Test func pendingTimelineOperationsPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "timeline-operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PendingTimelineOperationLibrary(fileURL: url)
        let id = UUID()
        try await library.save([.delete(id)])
        #expect(try await library.operations() == [.delete(id)])
    }

    @Test func firmwareJournalAndSHA256DetectPackageIdentity() async throws {
        let bytes = Data([1, 2, 3, 4])
        let blob = PBZFirmwareBlob(
            name: "firmware.bin", type: "normal", hardwareRevision: "EMERY",
            size: bytes.count, crc: PebbleCRC32.calculate([UInt8](bytes)),
            versionTag: nil, slot: nil
        )
        let package = PBZFirmwarePackage(
            manifest: PBZFirmwareManifest(manifestVersion: 1, firmware: blob, resources: nil),
            firmware: bytes,
            resources: nil
        )
        try package.validateIntegrity()
        #expect(package.sha256.count == 64)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PendingFirmwareUpdateLibrary(
            fileURL: directory.appending(path: "package.json"),
            journalURL: directory.appending(path: "journal.json")
        )
        let journal = FirmwareUpdateJournal(
            deviceID: "watch", hardwareRevision: "EMERY", previousVersion: nil,
            targetVersion: nil, packageSHA256: package.sha256
        )
        try await library.save(package, journal: journal)
        #expect(try await library.journal() == journal)
        try await library.updatePhase(.transferring)
        #expect(try await library.journal()?.phase == .transferring)
    }

    @Test func officialCatalogResponseMapsToInstallableApplication() throws {
        let json = """
        {
          "applications": [{
            "author": "Pebble Developer",
            "category": "Tools & Utilities",
            "description": "A useful app",
            "id": "store-id",
            "title": "Utility",
            "type": "watchapp",
            "uuid": "00112233-4455-6677-8899-aabbccddeeff",
            "hardware_platforms": [{"name":"emery"}],
            "icon_image": {"small":"https://example.com/icon.png"},
            "screenshot_images": [{"emery":"https://example.com/screenshot.png"}],
            "latest_release": {
              "pbw_file":"https://example.com/utility.pbw",
              "release_notes":"Improved reliability",
              "version":"2.0"
            }
          }]
        }
        """
        let home = try JSONDecoder().decode(OfficialCatalogHome.self, from: Data(json.utf8))
        let application = try #require(home.applications.first?.application(kind: .watchapp))
        #expect(application.name == "Utility")
        #expect(application.version == "2.0")
        #expect(application.supports(.pebbleTime2))
        #expect(!application.supports(.pebble2Duo))
        #expect(application.releaseNotes == "Improved reliability")
    }

    @Test func catalogVersionComparisonUsesNumericOrdering() {
        let application = PebbleCatalogApplication(
            id: UUID(), name: "App", developer: "Developer", version: "2.10",
            downloadURL: URL(string: "https://example.com/app.pbw")!, supportedPlatforms: ["emery"]
        )
        #expect(application.isNewer(than: "2.9"))
        #expect(!application.isNewer(than: "2.10"))
        #expect(!application.isNewer(than: "3.0"))
    }

    @Test func catalogSnapshotPersistsOfflineMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = PebbleCatalogApplication(
            id: UUID(), name: "Cached", developer: "Developer", version: "1.0",
            downloadURL: URL(string: "https://example.com/app.pbw")!, supportedPlatforms: ["emery"]
        )
        let snapshot = PebbleCatalogSnapshot(
            sourceURL: URL(string: "https://example.com/api")!, fetchedAt: Date(timeIntervalSince1970: 100),
            applications: [application]
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        let catalog = PebbleAppCatalog(cacheURL: url)
        #expect(try await catalog.cachedSnapshot() == snapshot)
    }

    @Test func reconnectBackoffGrowsExponentiallyAndCaps() {
        var backoff = PebbleReconnectBackoff(
            attempt: 0,
            initialDelay: .seconds(2),
            maximumDelay: .seconds(10)
        )

        #expect(backoff.nextDelay() == .seconds(2))
        #expect(backoff.nextDelay() == .seconds(4))
        #expect(backoff.nextDelay() == .seconds(8))
        #expect(backoff.nextDelay() == .seconds(10))
        #expect(backoff.nextDelay() == .seconds(10))

        backoff.reset()
        #expect(backoff.nextDelay() == .seconds(2))
    }

    @Test func corruptPendingOperationsAreQuarantinedAndRecovered() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "pending-timeline.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        let library = PendingTimelineOperationLibrary(fileURL: url)

        #expect(try await library.operations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(backups.count == 1)
        #expect(backups[0].hasPrefix("pending-timeline.json.corrupt-"))

        let operation = PendingTimelineOperation.delete(UUID())
        try await library.save([operation])
        #expect(try await library.operations() == [operation])
    }

    @Test func corruptCatalogIsQuarantinedAndReturnsNoSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x01]).write(to: url)
        let catalog = PebbleAppCatalog(cacheURL: url)

        #expect(try await catalog.cachedSnapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(backups.count == 1)
        #expect(backups[0].hasPrefix("catalog.json.corrupt-"))
    }
}
