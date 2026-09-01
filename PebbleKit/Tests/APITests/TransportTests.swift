import Foundation
import Testing
import ZIPFoundation
@testable import API

/// The PPoG transport, framing and byte transfers.
@Suite
@MainActor
struct TransportTests {
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

    @Test func putBytesInstallAcknowledgementIgnoresTheReturnedCookie() throws {
        // Real watches answer the install command with a different cookie;
        // rejecting it used to abort the transfer at the very last step.
        var session = PutBytesTransferSession(
            bytes: [0x01],
            objectType: .appExecutable,
            appBankID: 1,
            chunkSize: 4
        )
        _ = try session.start()
        _ = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42))
        _ = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42))
        #expect(try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42)) == [
            .send(PutBytesCodec.installFrame(cookie: 42)),
        ])

        #expect(try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 0)) == [.finished])
        #expect(session.completedCookie == 42)
    }

    @Test func putBytesRejectsAMismatchedCookieBeforeInstall() throws {
        var session = PutBytesTransferSession(
            bytes: [0x01],
            objectType: .appExecutable,
            appBankID: 1,
            chunkSize: 4
        )
        _ = try session.start()
        _ = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 42))
        #expect(throws: PutBytesTransferError.unexpectedCookie) {
            try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 43))
        }
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

    @Test func pebbleCRC32MatchesSTMWordAlgorithm() {
        // Golden values from the reference implementation's CrcCalculatorTest.
        #expect(PebbleCRC32.calculate([]) == 0xFFFFFFFF)
        #expect(PebbleCRC32.calculate([0xAB]) == 0x1D604014)
        #expect(PebbleCRC32.calculate([0x01, 0x02, 0x03, 0x04]) == 0x1DABE74F)
        #expect(PebbleCRC32.calculate([0x01, 0x02, 0x03, 0x04, 0x50, 0x06, 0x70, 0x08]) == 0x99F9E573)
    }

    @Test func pebbleCRC32ReversesTrailingPartialWords() {
        // Sizes that are not a multiple of four are the common case for app
        // binaries; packing the tail in place produced a CRC the watch NACKed.
        #expect(PebbleCRC32.calculate([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]) == 0x205DBD4F)
        #expect(PebbleCRC32.calculate([0x01, 0x02, 0x03]) == 0x6B6DC92A)
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
        // Three payload bytes per packet once the header allowance is taken off.
        let initialActions = try session.enqueue(
            Array(0..<10),
            maximumPacketSize: 3 + PPoGSession.headerOverhead
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

        #expect(decoder.append(Array(bytes.prefix(3))).frames.isEmpty)
        #expect(decoder.append(Array(bytes.dropFirst(3))) == PebbleProtocolFrameBatch(frames: [frame]))
    }

    @Test
    func pebbleProtocolDecoderKeepsTheFramesItDecodedBeforeABadLengthPrefix() throws {
        // The watch packs frames for unrelated endpoints into one delivery, so
        // an unusable length prefix part-way through must not take the frames
        // before it with it.
        let good = PebbleProtocolFrame(endpoint: 45, payload: [0x01, 0x02])
        var decoder = PebbleProtocolFrameDecoder()

        let batch = decoder.append(try good.encoded() + [0x00, 0x00, 0x00, 0x0B])

        #expect(batch.frames == [good])
        #expect(batch.failure == .emptyPayload)
    }

    @Test
    func pebbleProtocolDecoderResynchronisesAfterABadLengthPrefix() throws {
        // Only the four bytes that could not begin a frame are dropped, so a
        // stream that comes back onto a frame boundary decodes again.
        let next = PebbleProtocolFrame(endpoint: 6, payload: [0x07])
        var decoder = PebbleProtocolFrameDecoder()

        #expect(decoder.append([0x00, 0x00, 0x00, 0x0B]).failure == .emptyPayload)
        #expect(decoder.append(try next.encoded()) == PebbleProtocolFrameBatch(frames: [next]))
    }

    @Test
    func aRefusalNamesTheEndpointTheWatchWillNotAnswerOn() {
        // Recovery firmware answers a ping this way; reading it as a refusal
        // is what keeps the health check from dropping the link. The firmware's
        // meta endpoint has two of these: not implemented, and not allowed.
        let unhandled = PebbleProtocolFrame(endpoint: 0, payload: [0xDC, 0x07, 0xD1])
        #expect(unhandled.rejectedEndpoint == PingPongCodec.endpoint)
        let disallowed = PebbleProtocolFrame(endpoint: 0, payload: [0xDD, 0x07, 0xD1])
        #expect(disallowed.rejectedEndpoint == PingPongCodec.endpoint)

        // A corrupted-message reply names no endpoint, and neither does a
        // truncated one.
        #expect(PebbleProtocolFrame(endpoint: 0, payload: [0xD0]).rejectedEndpoint == nil)
        #expect(PebbleProtocolFrame(endpoint: 0, payload: [0xDC, 0x07]).rejectedEndpoint == nil)
        #expect(PebbleProtocolFrame(endpoint: 0, payload: [0x01, 0x07, 0xD1]).rejectedEndpoint == nil)
        #expect(PebbleProtocolFrame(endpoint: 11, payload: [0xDC, 0x07, 0xD1]).rejectedEndpoint == nil)
    }

    @Test
    func pebbleProtocolDecoderEmitsMultipleFrames() throws {
        let first = PebbleProtocolFrame(endpoint: 16, payload: [0x00])
        let second = PebbleProtocolFrame(endpoint: 18, payload: [0x01, 0x02])
        var decoder = PebbleProtocolFrameDecoder()

        let batch = decoder.append(try first.encoded() + second.encoded())

        #expect(batch.frames == [first, second])
        #expect(batch.failure == nil)
    }

    @Test
    func healthDataLoggingRefusesASessionItWasNeverOpenedFor() throws {
        // A session id means something only inside the session that opened it.
        // This is the property the client leans on when it throws its
        // processor away on a
        // disconnect: records for an id it has not been told about are refused,
        // so the watch opens the session again rather than having its records
        // read with a previous session's tag and item size.
        let sessionID: UInt8 = 3
        var open = [UInt8](repeating: 0, count: 29)
        open[0] = 0x01
        open[1] = sessionID
        // Tag 81 is the step record stream; six bytes an item.
        open[22] = 81
        open[27] = 6
        var data = [UInt8](repeating: 0, count: 10)
        data[0] = 0x02
        data[1] = sessionID
        let openFrame = PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: open)
        let dataFrame = PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: data)

        var established = HealthDataLoggingProcessor()
        #expect(try established.process(openFrame).response
            == HealthDataLoggingCodec.ackFrame(sessionID: sessionID))
        #expect(try established.process(dataFrame).response
            == HealthDataLoggingCodec.ackFrame(sessionID: sessionID))

        var reconnected = HealthDataLoggingProcessor()
        #expect(try reconnected.process(dataFrame).response
            == HealthDataLoggingCodec.nackFrame(sessionID: sessionID))
    }

    @Test func pendingNotificationsStayInOrderPerWatch() {
        var queue = PendingNotificationQueue()
        #expect(queue.isEmpty)
        #expect(!queue.holdsPackets(for: "watch-a"))

        queue.append(Data([1]), for: "watch-a")

        // Once a packet is waiting, later ones for that watch must wait too or
        // they would overtake it and stall the session.
        #expect(queue.holdsPackets(for: "watch-a"))
        // A different watch has its own ordering.
        #expect(!queue.holdsPackets(for: "watch-b"))

        queue.append(Data([2]), for: "watch-a")
        queue.append(Data([3]), for: "watch-b")
        #expect(queue.first?.value == Data([1]))
        queue.removeFirst()
        #expect(queue.first?.value == Data([2]))

        queue.removeAll(for: "watch-a")
        #expect(!queue.holdsPackets(for: "watch-a"))
        #expect(queue.first?.centralID == "watch-b")

        queue.removeAll()
        #expect(queue.isEmpty)
    }

    @Test
    func advertisementDecodesTheHardwarePlatform() {
        // Company identifier, payload type, 12-byte serial, then the extended
        // record whose first byte is the hardware platform.
        var manufacturerData: [UInt8] = [0x54, 0x01, 0x00]
        manufacturerData.append(contentsOf: Array("EMERY1234567".utf8.prefix(12)))
        manufacturerData.append(contentsOf: [18, 0x00, 5, 1, 0, 0])

        #expect(PebbleAdvertisement.model(
            advertisesPebbleService: false,
            localName: "Pebble 1A2B",
            manufacturerData: manufacturerData
        ) == .pebbleTime2)
    }

    @Test
    func advertisementKeepsWatchesWithoutAnExtendedScanRecord() {
        // A watch that was just reset advertises a generic name and may omit
        // the extended record; it still has to appear in the scan results.
        var manufacturerData: [UInt8] = [0xEA, 0x0E, 0x00]
        manufacturerData.append(contentsOf: Array("GABBRO123456".utf8.prefix(12)))

        #expect(PebbleAdvertisement.model(
            advertisesPebbleService: false,
            localName: "Pebble 1A2B",
            manufacturerData: manufacturerData
        ) != nil)
        // The pairing service alone is enough, without any manufacturer data.
        #expect(PebbleAdvertisement.model(
            advertisesPebbleService: true,
            localName: "Pebble 1A2B",
            manufacturerData: []
        ) != nil)
    }

    @Test
    func advertisementIgnoresUnsupportedAndForeignDevices() {
        var chalkWatch: [UInt8] = [0x54, 0x01, 0x00]
        chalkWatch.append(contentsOf: Array("CHALK1234567".utf8.prefix(12)))
        chalkWatch.append(contentsOf: [11, 0x00, 3, 0, 0, 0])
        // Platform 11 is a Pebble Time Round, which this app cannot drive.
        #expect(PebbleAdvertisement.model(
            advertisesPebbleService: false,
            localName: "Pebble Time Round 1A2B",
            manufacturerData: chalkWatch
        ) == nil)

        #expect(PebbleAdvertisement.model(
            advertisesPebbleService: false,
            localName: "Someone's Headphones",
            manufacturerData: [0x4C, 0x00, 0x01, 0x02]
        ) == nil)
    }

    @Test
    func supportedModelsUseProtocolCodenames() {
        #expect(PebbleWatchModel.pebble2Duo.rawValue == "FLINT")
        #expect(PebbleWatchModel.pebbleTime2.rawValue == "EMERY")
        #expect(PebbleWatchModel.pebbleRound2.rawValue == "GABBRO")
    }
}
