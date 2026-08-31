import Foundation
import Testing
import ZIPFoundation
@testable import API

/// Wire formats the watch and phone exchange.
@Suite
@MainActor
struct ProtocolCodecTests {
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
    func watchVersionCodecReportsRecoveryFirmware() throws {
        var payload = [UInt8](repeating: 0, count: 120)
        payload[0] = 0x01
        payload[45] = 0x01
        payload[46] = 15
        let frame = PebbleProtocolFrame(endpoint: 16, payload: payload)

        let information = try WatchVersionCodec.decode(frame)

        #expect(information.isRunningRecoveryFirmware)
        #expect(information.hardwarePlatform == 15)
    }

    @Test(arguments: [
        // flags, expected recovery, expected running slot
        (UInt8(0b0000), false, Int?.none),
        (UInt8(0b0001), true, Int?.none),
        // Dual slot without the slot-0 bit means slot 1 is running.
        (UInt8(0b0100), false, Int?.some(1)),
        (UInt8(0b1100), false, Int?.some(0)),
        // A normal dual-slot firmware must not read as recovery.
        (UInt8(0b1110), false, Int?.some(0)),
    ])
    func watchVersionCodecReadsFirmwareFlags(
        flags: UInt8,
        isRecovery: Bool,
        runningSlot: Int?
    ) throws {
        var payload = [UInt8](repeating: 0, count: 120)
        payload[0] = 0x01
        payload[45] = flags
        let frame = PebbleProtocolFrame(endpoint: 16, payload: payload)

        let information = try WatchVersionCodec.decode(frame)

        #expect(information.isRunningRecoveryFirmware == isRecovery)
        #expect(information.runningFirmwareSlot == runningSlot)
    }

    @Test
    func watchVersionCodecReadsTheLanguageAndCapabilities() throws {
        // The locale, its version and the capability bits sit after the two
        // firmware metadata blocks, the bootloader timestamp, board, serial,
        // Bluetooth address and resource version.
        var payload = [UInt8](repeating: 0, count: 150)
        payload[0] = 0x01
        payload.replaceSubrange(134..<140, with: Array("fr_FR".utf8) + [0])
        payload[140] = 0x00
        payload[141] = 0x26
        // Language packs are bit 4, the weather app bit 11, so the field reads
        // least significant byte first.
        payload[142] = 0b0001_0000
        payload[143] = 0b0000_1000

        let information = try WatchVersionCodec.decode(
            PebbleProtocolFrame(endpoint: 16, payload: payload)
        )

        #expect(information.languageLocale == "fr_FR")
        #expect(information.languageVersion == 38)
        #expect(information.supportsLanguagePacks)
        #expect(information.supportsWeatherApp)
    }

    @Test
    func aShorterVersionResponseSaysNothingAboutTheLanguage() throws {
        // Firmware old enough to stop after the serial number is still a valid
        // answer, and must not be read as "no language, no capabilities".
        var payload = [UInt8](repeating: 0, count: 120)
        payload[0] = 0x01

        let information = try WatchVersionCodec.decode(
            PebbleProtocolFrame(endpoint: 16, payload: payload)
        )

        #expect(information.languageLocale.isEmpty)
        #expect(information.languageVersion == 0)
        #expect(information.capabilities == 0)
        #expect(!information.supportsLanguagePacks)
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
    func pingPongCodecAcceptsTrailingBytesFromNewerFirmware() throws {
        let frame = PebbleProtocolFrame(
            endpoint: 2_001,
            payload: [0x00, 0x00, 0x00, 0x00, 0x2A, 0x00]
        )

        #expect(try PingPongCodec.decode(frame) == .ping(cookie: 42))
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

    @Test func integerBytesMatchTheProtocolByteOrder() {
        #expect(UInt32(0x1234_5678).bigEndianBytes == [0x12, 0x34, 0x56, 0x78])
        #expect(UInt32(0x1234_5678).littleEndianBytes == [0x78, 0x56, 0x34, 0x12])
        #expect(UInt16(0xABCD).bigEndianBytes == [0xAB, 0xCD])
        #expect(UInt16(0xABCD).littleEndianBytes == [0xCD, 0xAB])
        #expect(UInt8(0x0F).bigEndianBytes == [0x0F])
        // A signed value keeps its two's-complement representation.
        #expect(Int32(-2).littleEndianBytes == [0xFE, 0xFF, 0xFF, 0xFF])
        #expect(Int16(-1).bigEndianBytes == [0xFF, 0xFF])
    }

    @Test func hexadecimalStringPadsEveryByte() {
        #expect([UInt8(0x00), 0x0F, 0xA0, 0xFF].hexadecimalString == "000fa0ff")
        #expect([UInt8]().hexadecimalString.isEmpty)
    }

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
}
