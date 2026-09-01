import CoreBluetooth
import Foundation
import Testing
@testable import API

@Suite
@MainActor
struct MusicControlTests {
    @Test func nowPlayingFrameMatchesReferenceVector() throws {
        let frame = MusicControlCodec.nowPlayingFrame(MusicNowPlaying(
            artist: "A",
            album: "B",
            title: "C",
            durationMilliseconds: 10,
            trackCount: 20,
            trackNumber: 30
        ))

        // Golden vector from libpebble3's MusicTest.
        #expect(try frame.encoded() == [
            0x00, 0x13, 0x00, 0x20,
            0x10,
            0x01, 0x41,
            0x01, 0x42,
            0x01, 0x43,
            0x0A, 0x00, 0x00, 0x00,
            0x14, 0x00, 0x00, 0x00,
            0x1E, 0x00, 0x00, 0x00,
        ])
    }

    @Test func nowPlayingFrameOmitsAbsentOptionalFields() throws {
        let frame = MusicControlCodec.nowPlayingFrame(MusicNowPlaying(artist: "A", album: "B", title: "C"))
        #expect(try frame.encoded() == [
            0x00, 0x07, 0x00, 0x20,
            0x10, 0x01, 0x41, 0x01, 0x42, 0x01, 0x43,
        ])
    }

    @Test func nowPlayingFrameDropsTrackNumberWithoutDuration() {
        let frame = MusicControlCodec.nowPlayingFrame(MusicNowPlaying(
            artist: "A",
            album: "B",
            title: "C",
            durationMilliseconds: nil,
            trackCount: 20,
            trackNumber: 30
        ))
        // Optional fields are positional: nothing after a missing field may be encoded.
        #expect(frame.payload.count == 7)
    }

    @Test func playbackStatusFrameUsesThirteenBytePayload() {
        let frame = MusicControlCodec.playbackStatusFrame(MusicPlaybackStatus(
            state: .playing,
            positionMilliseconds: 1_000,
            playRatePercent: 100,
            shuffle: .on,
            repeatState: .all,
            skipSeeksWithinTrack: true
        ))
        #expect(frame.payload == [
            0x11, 0x01,
            0xE8, 0x03, 0x00, 0x00,
            0x64, 0x00, 0x00, 0x00,
            0x02, 0x03, 0x01,
        ])
    }

    @Test func volumeAndPlayerInfoFrames() {
        #expect(MusicControlCodec.volumeFrame(percent: 80).payload == [0x12, 0x50])
        #expect(MusicControlCodec.playerInfoFrame(package: "p", name: "N").payload == [0x13, 0x01, 0x70, 0x01, 0x4E])
    }

    @Test func decodesWatchActionsAndUpdateRequests() throws {
        #expect(try MusicControlCodec.decode(
            PebbleProtocolFrame(endpoint: 32, payload: [0x01])
        ) == .action(.playPause))
        #expect(try MusicControlCodec.decode(
            PebbleProtocolFrame(endpoint: 32, payload: [0x08])
        ) == .updateRequested)
        #expect(throws: MusicControlCodecError.unknownCommand) {
            try MusicControlCodec.decode(PebbleProtocolFrame(endpoint: 32, payload: [0x77]))
        }
    }

    @Test func longTitlesAreTruncatedForTheLengthPrefix() {
        let title = String(repeating: "あ", count: 100)
        let frame = MusicControlCodec.nowPlayingFrame(MusicNowPlaying(artist: "", album: "", title: title))
        let titleLength = Int(frame.payload[3])
        #expect(titleLength <= 255)
        // 64 characters of 3-byte UTF-8.
        #expect(titleLength == 192)
    }
}

@Suite
@MainActor
struct PhoneControlTests {
    @Test func incomingCallFrameUsesOfficialLayout() {
        let frame = PhoneControlCodec.incomingCallFrame(
            cookie: 0x0102_0304,
            callerNumber: "123",
            callerName: "Ann"
        )
        #expect(frame.endpoint == 33)
        #expect(frame.payload == [
            0x04,
            0x01, 0x02, 0x03, 0x04,
            0x03, 0x31, 0x32, 0x33,
            0x03, 0x41, 0x6E, 0x6E,
        ])
    }

    @Test func missingCallerNameFallsBackToTheNumber() {
        let frame = PhoneControlCodec.incomingCallFrame(cookie: 1, callerNumber: "555", callerName: nil)
        #expect(Array(frame.payload.suffix(8)) == [0x03, 0x35, 0x35, 0x35, 0x03, 0x35, 0x35, 0x35])
    }

    @Test func startAndEndFramesCarryTheCookie() {
        #expect(PhoneControlCodec.callStartFrame(cookie: 0xAABB_CCDD).payload == [0x08, 0xAA, 0xBB, 0xCC, 0xDD])
        #expect(PhoneControlCodec.callEndFrame(cookie: 0xAABB_CCDD).payload == [0x09, 0xAA, 0xBB, 0xCC, 0xDD])
    }

    @Test func decodesAnswerAndHangupActions() throws {
        #expect(try PhoneControlCodec.decode(
            PebbleProtocolFrame(endpoint: 33, payload: [0x01, 0x01, 0x02, 0x03, 0x04])
        ) == .answer(cookie: 0x0102_0304))
        #expect(try PhoneControlCodec.decode(
            PebbleProtocolFrame(endpoint: 33, payload: [0x02, 0x00, 0x00, 0x00, 0x07])
        ) == .hangup(cookie: 7))
    }
}

@Suite
@MainActor
struct GattServerTests {
    @Test func serviceUsesTheForwardTransportUUIDs() {
        // The phone hosts these when the watch has no protocol service of its
        // own; the values have to match what the watch looks for.
        #expect(PebbleGattServer.serviceUUID.uuidString == "10000000-328E-0FBB-C642-1AA6699BDADA")
        #expect(PebbleGattServer.dataCharacteristicUUID.uuidString == "10000001-328E-0FBB-C642-1AA6699BDADA")
        #expect(PebbleGattServer.metaCharacteristicUUID.uuidString == "10000002-328E-0FBB-C642-1AA6699BDADA")
    }

    @Test func sendingWithoutASubscribedWatchFails() {
        let server = PebbleGattServer.shared
        #expect(!server.isSubscribed(centralID: "unknown-watch"))
        #expect(!server.send([0x01, 0x02], to: "unknown-watch"))
        // An unsubscribed watch falls back to the smallest possible payload.
        #expect(server.maximumPacketSize(centralID: "unknown-watch") == 20)
    }
}

@Suite
@MainActor
struct PairingTests {
    @Test func connectivityStatusDecodesFlags() throws {
        // A watch that has just been reset: connected, not paired, not
        // encrypted, and no pairing error yet.
        let fresh = try #require(PebbleConnectivityStatus(decoding: [0b1, 0, 0, 0]))
        #expect(fresh.isConnected)
        #expect(!fresh.isPaired)
        #expect(!fresh.isEncrypted)
        #expect(!fresh.isReadyForProtocol)

        let bonded = try #require(PebbleConnectivityStatus(decoding: [0b111, 0, 0, 0]))
        #expect(bonded.isReadyForProtocol)

        // Paired but unencrypted means the phone forgot the bond.
        let stale = try #require(PebbleConnectivityStatus(decoding: [0b10_0011, 0, 0, 8]))
        #expect(stale.isPaired)
        #expect(!stale.isEncrypted)
        #expect(stale.hasRemoteAttemptedToUseStalePairing)
        #expect(stale.pairingError == 8)
        #expect(!stale.isReadyForProtocol)
    }

    @Test func connectivityStatusRejectsTruncatedValues() {
        // Watches wedged in a bad state report a short value.
        #expect(PebbleConnectivityStatus(decoding: []) == nil)
        #expect(PebbleConnectivityStatus(decoding: [0b111, 0, 0]) == nil)
    }

    @Test func pairingTriggerAsksTheWatchForASecurityRequest() {
        // Only the watch can start bonding, so the default value sets the
        // force-security-request bit and nothing else.
        #expect(PebblePairingTrigger.value() == [0b100])
        #expect(PebblePairingTrigger.value(noSecurityRequest: true) == [0b10])
        #expect(PebblePairingTrigger.value(pinAddress: true) == [0b101])
        #expect(PebblePairingTrigger.value(watchAsGattServer: true) == [0b1_0100])
    }
}

@Suite
@MainActor
struct ResetTests {
    @Test func resetFramesUseTheOfficialWireValues() {
        #expect(ResetCodec.frame(.restart) == PebbleProtocolFrame(endpoint: 2_003, payload: [0x00]))
        #expect(ResetCodec.frame(.recoveryFirmware) == PebbleProtocolFrame(endpoint: 2_003, payload: [0xFF]))
        #expect(ResetCodec.frame(.factoryReset) == PebbleProtocolFrame(endpoint: 2_003, payload: [0xFE]))
    }
}

@Suite
@MainActor
struct PhoneVersionTests {
    @Test func recognizesVersionRequests() {
        #expect(PhoneVersionCodec.isRequest(PebbleProtocolFrame(endpoint: 17, payload: [0x00])))
        #expect(!PhoneVersionCodec.isRequest(PebbleProtocolFrame(endpoint: 17, payload: [0x01])))
        #expect(!PhoneVersionCodec.isRequest(PebbleProtocolFrame(endpoint: 16, payload: [0x00])))
    }

    @Test func responseAdvertisesNotificationFiltering() {
        let frame = PhoneVersionCodec.responseFrame(operatingSystem: .iOS)
        #expect(frame.endpoint == 17)
        #expect(frame.payload.count == 25)
        #expect(frame.payload[0] == 0x01)
        #expect(Array(frame.payload[1..<5]) == [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(Array(frame.payload[5..<9]) == [0x00, 0x00, 0x00, 0x00])
        // OS identifier 1 (iOS) combined with the BTLE platform bit.
        #expect(Array(frame.payload[9..<13]) == [0x00, 0x00, 0x00, 0x81])
        #expect(Array(frame.payload[13..<17]) == [0x02, 0x04, 0x04, 0x02])
        // Capability bit 9 (notification filtering) lives in the second byte.
        #expect(frame.payload[18] & 0x02 == 0x02)
    }

    @Test func capabilityBytesPackBitPositions() {
        let bytes = PhoneVersionCodec.capabilityBytes([.appRunStateProtocol, .notificationFiltering])
        #expect(bytes == [0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    @Test func theBitmaskClaimsEveryFeatureThisAppHoldsUpItsEndOf() {
        // `PebbleProtocolCapabilities`, in the firmware's order: run state 0,
        // infinite log dumping 1, extended music 2, 8k app message 5, voice 7,
        // notification filtering 9, unread coredump 10, weather 11, reminders
        // 12, smooth firmware install progress 14.
        let frame = PhoneVersionCodec.responseFrame(operatingSystem: .iOS)

        #expect(Array(frame.payload[17..<25]) == [0xA7, 0x5E, 0, 0, 0, 0, 0, 0])
        // Without bit 2 the watch reads only the first three fields of a
        // now-playing frame and reports no music capabilities at all.
        #expect(PhoneVersionCodec.capabilityBytes([.extendedMusicProtocol])
            == [0x04, 0, 0, 0, 0, 0, 0, 0])
        // Without bit 14 `system_message.c` ignores the byte counts we send it
        // and falls back to the legacy firmware-update path.
        #expect(PhoneVersionCodec.capabilityBytes([.smoothFirmwareInstallProgress])
            == [0x00, 0x40, 0, 0, 0, 0, 0, 0])
        // Without bit 12 `reminder_app_get_info` hides the Reminders app.
        #expect(PhoneVersionCodec.capabilityBytes([.remindersApp])
            == [0x00, 0x10, 0, 0, 0, 0, 0, 0])
        // Nothing here sends a text message, teaches the watch a language, or
        // syncs its settings back, so none of those are claimed.
        #expect(!PhoneVersionCodec.supportedCapabilities.contains(.sendTextApp))
        #expect(!PhoneVersionCodec.supportedCapabilities.contains(.localization))
        #expect(!PhoneVersionCodec.supportedCapabilities.contains(.workoutApp))
    }

    @Test func theWeatherClaimIsMadeOrTheWatchRefusesTheWrite() {
        // `weather_service_supported_by_phone` reads this bit from the answer
        // given while connecting, and refuses every weather write without it.
        #expect(PhoneVersionCodec.supportedCapabilities.contains(.weatherApp))
        let frame = PhoneVersionCodec.responseFrame(operatingSystem: .iOS)
        #expect(frame.payload[18] & 0x08 == 0x08)
    }
}

@Suite
@MainActor
struct ImagingTests {
    @Test func anAlbumArtRequestCarriesWhatIsPlaying() throws {
        let frame = PebbleProtocolFrame(endpoint: 53, payload: [
            0x01, 0x07, 0x00, 0x02, 0x50, 0x00, 0x3C, 0x00,
            0x01, 0x41,
            0x01, 0x42,
        ])

        let request = try ImagingCodec.decode(frame)

        #expect(request == .albumArt(
            PebbleImageRequestHeader(token: 7, kindValue: 0, format: 2, width: 80, height: 60),
            title: "A",
            artist: "B"
        ))
    }

    @Test func aKindThisAppHasNeverHeardOfIsStillAnswerable() throws {
        let request = try ImagingCodec.decode(PebbleProtocolFrame(
            endpoint: 53,
            payload: [0x01, 0x09, 0x7F, 0x02, 0x10, 0x00, 0x10, 0x00]
        ))

        #expect(request == .unsupported(
            PebbleImageRequestHeader(token: 9, kindValue: 0x7F, format: 2, width: 16, height: 16)
        ))
        // The kind rides in the top nibble of the flags byte, and only four
        // bits of it fit.
        #expect(ImagingCodec.unsupportedFrame(token: 9, kindValue: 0x7F).payload
            == [0x02, 0x09, 0xF8, 0, 0, 0, 0, 0, 0])
    }

    @Test func aPictureIsSentAsChunksWithTheHeaderOnTheFirst() {
        let image = PebbleEncodedImage(
            width: 4,
            height: 4,
            palette: [0xC0, 0xFF],
            pixels: [UInt8](repeating: 0x01, count: 8)
        )

        let frames = ImagingCodec.responseFrames(token: 3, kindValue: 0, image: image)

        #expect(frames.count == 1)
        let payload = frames[0].payload
        #expect(Array(payload.prefix(9)) == [0x02, 0x03, 0x03, 0, 0, 0, 0, 8, 0])
        // Size, then the format and how many colours the palette holds.
        #expect(Array(payload[9..<15]) == [4, 0, 4, 0, 0x02, 0x02])
        #expect(Array(payload[15..<17]) == [0xC0, 0xFF])
        #expect(Array(payload.suffix(8)) == image.pixels)
    }

    @Test func aPictureTooLargeForOneFrameIsSplitAndTheLastSaysSo() {
        let image = PebbleEncodedImage(
            width: 100,
            height: 30,
            palette: [0xC0],
            pixels: [UInt8](repeating: 0, count: 1_500)
        )

        let frames = ImagingCodec.responseFrames(token: 1, kindValue: 1, image: image)

        #expect(frames.count == 2)
        // First and not last, then last and not first, with the kind in the
        // top nibble of both.
        #expect(frames[0].payload[2] == 0x11)
        #expect(frames[1].payload[2] == 0x12)
        #expect(Array(frames[1].payload[3..<7]) == [0xE8, 0x03, 0x00, 0x00])
    }

    @Test func aPictureIsReducedToTheColoursTheWatchHas() throws {
        // A red and a blue half: two colours out of the sixteen available, and
        // no dithering to invent a third.
        var argb: [UInt32] = []
        for _ in 0..<8 {
            argb += [UInt32](repeating: 0xFFFF_0000, count: 4)
            argb += [UInt32](repeating: 0xFF00_00FF, count: 4)
        }

        let image = try #require(PebbleImageEncoder.encode(argb: argb, width: 8, height: 8))

        #expect(image.palette.count == 2)
        #expect(image.palette.allSatisfy { $0 & 0b1100_0000 == 0b1100_0000 })
        #expect(image.palette.contains(0b1111_0000))
        #expect(image.palette.contains(0b1100_0011))
        // Two pixels to the byte, each row padded out to a whole byte.
        #expect(image.pixels.count == 4 * 8)
        let red = image.palette.firstIndex(of: 0b1111_0000).map { UInt8($0) }
        #expect(image.pixels[0] >> 4 == red)
        #expect(image.pixels[0] & 0x0F == red)
    }
}

@Suite
@MainActor
struct WatchDiagnosticsTests {
    private func screenshotFrame(_ payload: [UInt8]) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: 8_000, payload: payload)
    }

    @Test func aColourScreenshotArrivesAsAHeaderAndThenPixels() throws {
        var collector = ScreenshotCollector()
        // Two by two, eight bits a pixel. The header counts in network order.
        let header: [UInt8] = [0x00] + UInt32(2).bigEndianBytes
            + UInt32(2).bigEndianBytes + UInt32(2).bigEndianBytes

        #expect(try collector.accept(screenshotFrame(header + [0xFF, 0xC0])) == nil)
        let screenshot = try #require(try collector.accept(screenshotFrame([0xF0, 0xC3])))

        #expect(screenshot.width == 2)
        #expect(screenshot.height == 2)
        #expect(screenshot.pixels == [0xFFFF_FFFF, 0xFF00_0000, 0xFFFF_0000, 0xFF00_00FF])
    }

    @Test func aBlackAndWhiteScreenshotIsOneBitAPixelFromTheLowestUp() throws {
        var collector = ScreenshotCollector()
        let header: [UInt8] = [0x00] + UInt32(1).bigEndianBytes
            + UInt32(8).bigEndianBytes + UInt32(1).bigEndianBytes

        let screenshot = try #require(try collector.accept(screenshotFrame(header + [0b0000_0101])))

        #expect(screenshot.pixels.count == 8)
        #expect(screenshot.pixels[0] == 0xFFFF_FFFF)
        #expect(screenshot.pixels[1] == 0xFF00_0000)
        #expect(screenshot.pixels[2] == 0xFFFF_FFFF)
    }

    @Test func aWatchThatWillNotTakeAPictureSaysWhy() {
        var collector = ScreenshotCollector()
        let refusal: [UInt8] = [0x03] + UInt32(1).bigEndianBytes
            + UInt32(0).bigEndianBytes + UInt32(0).bigEndianBytes

        #expect(throws: ScreenshotError.refused(3)) {
            try collector.accept(screenshotFrame(refusal))
        }
    }

    @Test func aLogLineIsTheFirmwaresOwnRecord() throws {
        // `pbl_log_binary_format` puts the timestamp through `htonl` and the
        // line number through `htons` before it hands the buffer over, and both
        // are unconditional byte swaps, so the two numbers arrive most
        // significant byte first. Read the other way round, this record would
        // be dated 1970 and blame line 16641. The cookie is not the firmware's
        // to read: it is copied out of the request and back verbatim.
        var payload: [UInt8] = [0x80] + UInt32(0x1234_5678).littleEndianBytes
        payload += [0x66, 0x00, 0x00, 0x00]
        payload += [50, 5]
        payload += [0x01, 0x41]
        payload += Array("main.c".utf8) + [UInt8](repeating: 0, count: 10)
        payload += Array("hello".utf8)

        let message = try LogDumpCodec.decode(
            PebbleProtocolFrame(endpoint: 2_002, payload: payload),
            cookie: 0x1234_5678
        )

        guard case .line(let line) = message else {
            Issue.record("expected a line")
            return
        }
        #expect(line.date == Date(timeIntervalSince1970: 0x6600_0000))
        #expect(line.level == 50)
        #expect(line.levelName == "W")
        #expect(line.file == "main.c")
        #expect(line.line == 321)
        #expect(line.message == "hello")
    }

    @Test func aRequestAndItsAnswerAgreeOnTheCookiesByteOrder() throws {
        // The watch reads the four bytes out of the request into a word and
        // writes that word back into every reply, so whichever order they go
        // out in is the order they come back in.
        let request = LogDumpCodec.requestFrame(generation: 0, cookie: 0x1234_5678)

        #expect(request.payload == [0x10, 0x00, 0x78, 0x56, 0x34, 0x12])
        #expect(try LogDumpCodec.decode(
            PebbleProtocolFrame(endpoint: 2_002, payload: [0x81] + Array(request.payload.dropFirst(2))),
            cookie: 0x1234_5678
        ) == .done)
    }

    @Test func aLineForSomebodyElsesRequestIsIgnored() throws {
        let payload: [UInt8] = [0x81] + UInt32(7).littleEndianBytes

        #expect(try LogDumpCodec.decode(
            PebbleProtocolFrame(endpoint: 2_002, payload: payload),
            cookie: 8
        ) == nil)
        #expect(try LogDumpCodec.decode(
            PebbleProtocolFrame(endpoint: 2_002, payload: payload),
            cookie: 7
        ) == .done)
    }

    @Test func anAppLogLineNamesTheAppThatWroteIt() throws {
        let id = UUID(uuidString: "01020304-0506-0708-090A-0B0C0D0E0F10")!
        // `app_log_vargs` builds its record with the same
        // `pbl_log_binary_format`, so its numbers are the same way round.
        var payload = BlobDBCodec.uuidBytes(id)
        payload += UInt32(100).bigEndianBytes
        payload += [200, 2]
        payload += UInt16(9).bigEndianBytes
        payload += Array("a.c".utf8) + [UInt8](repeating: 0, count: 13)
        payload += Array("hi".utf8)

        let (applicationID, line) = try AppLogCodec.decode(
            PebbleProtocolFrame(endpoint: 2_006, payload: payload)
        )

        #expect(applicationID == id)
        #expect(line.date == Date(timeIntervalSince1970: 100))
        #expect(line.line == 9)
        #expect(line.message == "hi")
        #expect(AppLogCodec.enableFrame(true).payload == [1])
    }

    @Test func anObjectIsPulledInOrderUntilItsSizeIsReached() throws {
        var collector = GetBytesCollector(transactionID: 9)
        let info: [UInt8] = [0x01, 9, 0x00] + UInt32(6).bigEndianBytes

        #expect(try collector.accept(PebbleProtocolFrame(endpoint: 9_000, payload: info)) == nil)
        let first: [UInt8] = [0x02, 9] + UInt32(0).bigEndianBytes + [0xAA, 0xBB, 0xCC]
        #expect(try collector.accept(PebbleProtocolFrame(endpoint: 9_000, payload: first)) == nil)
        let second: [UInt8] = [0x02, 9] + UInt32(3).bigEndianBytes + [0xDD, 0xEE, 0xFF]

        #expect(try collector.accept(PebbleProtocolFrame(endpoint: 9_000, payload: second))
            == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    @Test func aChunkThatDoesNotFollowOnIsRefusedRatherThanStitchedIn() throws {
        var collector = GetBytesCollector(transactionID: 1)
        let info: [UInt8] = [0x01, 1, 0x00] + UInt32(4).bigEndianBytes
        _ = try collector.accept(PebbleProtocolFrame(endpoint: 9_000, payload: info))
        let outOfOrder: [UInt8] = [0x02, 1] + UInt32(2).bigEndianBytes + [0x01, 0x02]

        #expect(throws: GetBytesError.outOfOrderChunk) {
            try collector.accept(PebbleProtocolFrame(endpoint: 9_000, payload: outOfOrder))
        }
        // Another transaction's answer is not this caller's to complain about.
        #expect(try collector.accept(PebbleProtocolFrame(endpoint: 9_000, payload: [0x02, 2, 0, 0, 0, 0])) == nil)
    }

    @Test func anObjectBiggerThanAnyWatchIsRefusedRatherThanReservedFor() {
        // The size is believed before a byte of the object has arrived, so a
        // corrupt OBJECT_INFO would otherwise have the app reserve four
        // gigabytes and be killed for it.
        var collector = GetBytesCollector(transactionID: 4)
        let corrupt: [UInt8] = [0x01, 4, 0x00] + UInt32.max.bigEndianBytes

        #expect(throws: GetBytesError.objectTooLarge(Int(UInt32.max))) {
            try collector.accept(PebbleProtocolFrame(endpoint: 9_000, payload: corrupt))
        }

        let ceiling = GetBytesCodec.maximumObjectByteCount
        let justOver: [UInt8] = [0x01, 4, 0x00] + UInt32(ceiling + 1).bigEndianBytes
        #expect(throws: GetBytesError.objectTooLarge(ceiling + 1)) {
            try collector.accept(PebbleProtocolFrame(endpoint: 9_000, payload: justOver))
        }
    }

    @Test func aRequestForAFileCarriesItsName() {
        #expect(GetBytesCodec.requestFrame(.coredump, transactionID: 3).payload == [0x00, 3])
        #expect(GetBytesCodec.requestFrame(.unreadCoredump, transactionID: 3).payload == [0x05, 3])
        #expect(GetBytesCodec.requestFrame(.file(name: "ab"), transactionID: 3).payload
            == [0x03, 3, 2, 0x61, 0x62])
    }

    @Test func aColourIsSixBitsAndAlwaysOpaque() {
        let colour = PebbleColor(red: 3, green: 0, blue: 2)

        #expect(colour.argb == 0b1111_0010)
        #expect(PebbleColor(argb: 0b1111_0010) == colour)
        // A value without the alpha bits is not one of the watch's colours.
        #expect(PebbleColor(argb: 0b0011_0010) == nil)
        #expect(PebbleColor.all.count == 64)
        #expect(PebbleColor.all.allSatisfy { PebbleColor(argb: $0.argb) == $0 })
    }

    @Test func anAppsColoursRideOnItsRecord() {
        var app = NotificationSourceApp(
            bundleID: "com.example.chat",
            displayName: "Chat",
            stateUpdated: Date(timeIntervalSince1970: 0)
        )
        app.backgroundColor = PebbleColor(red: 3, green: 0, blue: 0)
        app.foregroundColor = .white

        let value = NotificationAppsCodec.value(for: app)

        #expect(value[4] == 6)
        #expect(Array(value.suffix(8)) == [28, 0x01, 0x00, 0b1111_0000, 27, 0x01, 0x00, 0b1111_1111])
    }
}

@Suite
@MainActor
struct WatchSettingsTests {
    @Test func aSettingIsWrittenAsOneByteUnderItsFirmwareName() {
        let frame = WatchSettingsCodec.insertFrame(.clock24Hour, isOn: true, token: 0x0102)

        #expect(frame.endpoint == BlobDBCodec.endpoint)
        // The settings database, whose whitelist is keyed by the firmware's own
        // preference names — with the terminator it writes them with.
        #expect(frame.payload[3] == 0x0C)
        #expect(Array(frame.payload[5..<(5 + 9)]) == Array("clock24h".utf8) + [0])
        #expect(frame.payload[4] == 9)
        #expect(Array(frame.payload.suffix(3)) == [0x01, 0x00, 0x01])
    }

    @Test func theActivityRecordMatchesTheFirmwareStruct() {
        // `ActivitySettings`, packed: two little-endian int16s, three flags,
        // then age and gender as signed bytes.
        let settings = PebbleActivitySettings(
            heightMillimetres: 1_750,
            weightDecagrams: 7_250,
            isTrackingEnabled: true,
            areActivityInsightsEnabled: false,
            areSleepInsightsEnabled: true,
            ageYears: 34,
            gender: 1
        )

        #expect(settings.encoded() == [0xD6, 0x06, 0x52, 0x1C, 0x01, 0x00, 0x01, 0x22, 0x01])
        #expect(settings.encoded().count == 9)
    }

    @Test func theHeartRateRecordIsThreeBytes() {
        let settings = PebbleHeartRateSettings(
            isEnabled: true,
            interval: .everyHour,
            isEnabledDuringActivity: false
        )

        #expect(settings.encoded() == [0x01, 0x02, 0x00])
    }

    @Test func theHeartRateIntervalsAreTheFourTheWatchHas() {
        // `HRMonitoringInterval`: 10Min = 0, 30Min = 1, 1Hour = 2,
        // Disabled = 3. The raw value goes straight into
        // `ActivityHRMSettings.measurement_interval`, so numbering them any
        // other way turns "off" into a reading every ten minutes.
        #expect(PebbleHeartRateInterval.everyTenMinutes.rawValue == 0)
        #expect(PebbleHeartRateInterval.everyThirtyMinutes.rawValue == 1)
        #expect(PebbleHeartRateInterval.everyHour.rawValue == 2)
        #expect(PebbleHeartRateInterval.off.rawValue == 3)
        #expect(PebbleHeartRateInterval.allCases.count == 4)

        let off = PebbleHeartRateSettings(
            isEnabled: false,
            interval: .off,
            isEnabledDuringActivity: false
        )
        #expect(off.encoded() == [0x00, 0x03, 0x00])
    }

    @Test func turningTheHeartRateOffStopsTheSamplingAsWell() {
        // The watch's sampling loop reads only the interval, and its `enabled`
        // flag only decides whether an app may ask for a reading, so a reader
        // who turns the heart rate off keeps paying for it in battery unless
        // the interval is sent as Disabled too.
        let settings = PebbleHeartRateSettings(
            isEnabled: false,
            interval: .everyTenMinutes,
            isEnabledDuringActivity: true
        )

        #expect(settings.encoded() == [0x00, 0x03, 0x01])
    }

    @Test func aHeartRateSettingSavedUnderOtherNumbersStillOpens() throws {
        let stored = Data(#"{"isEnabled":true,"interval":9,"isEnabledDuringActivity":true}"#.utf8)

        let settings = try JSONDecoder().decode(PebbleHeartRateSettings.self, from: stored)

        #expect(settings.interval == .everyTenMinutes)
        #expect(settings.isEnabled)
    }

    @Test func aHealthDayIsKeyedByItsWeekdayAndMeasuredInWords() {
        let day = PebbleHealthDay(
            weekday: 1,
            lastProcessed: Date(timeIntervalSince1970: 0x66000000),
            steps: 8_000,
            activeKilocalories: 0,
            restingKilocalories: 0,
            distanceMetres: 0,
            activeSeconds: 0,
            sleepSeconds: 25_200,
            deepSleepSeconds: 0
        )

        #expect(HealthStatsCodec.movementKey(weekday: day.weekday) == "monday_movementData")
        #expect(HealthStatsCodec.sleepKey(weekday: day.weekday) == "monday_sleepData")
        // The firmware refuses a value whose length is not a multiple of four.
        #expect(HealthStatsCodec.movementValue(for: day).count % 4 == 0)
        #expect(HealthStatsCodec.sleepValue(for: day).count % 4 == 0)
        #expect(HealthStatsCodec.movementValue(for: day).prefix(12) == [
            0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x66,
            0x40, 0x1F, 0x00, 0x00,
        ])
        #expect(HealthStatsCodec.movementFrame(for: day, token: 1).payload[3] == 0x0A)
    }

    @Test func theRemindersAppIsTurnedOnThroughItsOwnPreference() {
        let frame = WeatherCodec.reminderAppFrame(state: .enabled, token: 1)

        #expect(frame.payload[3] == 9)
        #expect(Array(frame.payload[5..<17]) == Array("remindersApp".utf8))
        #expect(Array(frame.payload.suffix(1)) == [2])
    }
}

@Suite
@MainActor
struct WeatherTests {
    private let report = PebbleWeatherReport(
        id: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
        locationName: "Kyoto",
        isCurrentLocation: true,
        currentTemperature: 21,
        currentType: .sun,
        todayHigh: 26,
        todayLow: 18,
        tomorrowType: .lightRain,
        tomorrowHigh: 24,
        tomorrowLow: 17,
        shortPhrase: "Clear",
        updated: Date(timeIntervalSince1970: 0x66000000)
    )

    @Test func theRecordMatchesTheFirmwareStruct() {
        // WeatherDBEntry, packed and little-endian: version, current, today,
        // tomorrow, when it was taken, whether it is where the phone is, then
        // the two strings as a serialized array of pstring16s.
        #expect(WeatherCodec.value(for: report) == [
            0x03,
            0x15, 0x00,
            0x07,
            0x1A, 0x00,
            0x12, 0x00,
            0x03,
            0x18, 0x00,
            0x11, 0x00,
            0x00, 0x00, 0x00, 0x66,
            0x01,
            // The strings' total size: two lengths of two bytes and ten of text.
            0x0E, 0x00,
            0x05, 0x00, 0x4B, 0x79, 0x6F, 0x74, 0x6F,
            0x05, 0x00, 0x43, 0x6C, 0x65, 0x61, 0x72,
        ])
    }

    @Test func theRecordGoesIntoTheWeatherDatabaseUnderTheLocationsKey() {
        let frame = WeatherCodec.insertFrame(report: report, token: 0x1234)

        #expect(frame.endpoint == BlobDBCodec.endpoint)
        #expect(frame.payload[0] == 0x01)
        #expect(Array(frame.payload[1..<3]) == [0x12, 0x34])
        // Database 5 is the weather one.
        #expect(frame.payload[3] == 5)
        #expect(frame.payload[4] == 16)
        #expect(Array(frame.payload[5..<21]) == BlobDBCodec.uuidBytes(report.id))
    }

    @Test func theWeatherAppIsAlsoToldWhichPlacesToShow() {
        // A forecast the watch holds but this list does not name is skipped by
        // the weather app — "has no known ordering" — even though a watchface
        // reading the database directly shows it.
        let second = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!
        let frame = WeatherCodec.preferencesFrame(orderedIDs: [report.id, second], token: 0x0102)

        #expect(frame.payload[0] == 0x01)
        #expect(Array(frame.payload[1..<3]) == [0x01, 0x02])
        // The ordering lives in the watch app preferences database, under a
        // name rather than a UUID.
        #expect(frame.payload[3] == 9)
        #expect(frame.payload[4] == UInt8("weatherApp".utf8.count))
        #expect(Array(frame.payload[5..<15]) == Array("weatherApp".utf8))
        #expect(Array(frame.payload[15..<17]) == UInt16(33).littleEndianBytes)
        #expect(frame.payload[17] == 2)
        #expect(Array(frame.payload[18..<34]) == BlobDBCodec.uuidBytes(report.id))
        #expect(Array(frame.payload[34..<50]) == BlobDBCodec.uuidBytes(second))
    }

    @Test func aNameLongerThanTheWatchsBufferIsCutBetweenCharacters() {
        // The firmware keeps 64 bytes for the name and wants room for a
        // terminator, and a kanji costs three bytes — cutting by character
        // count would overrun it, cutting mid-character would corrupt it.
        let long = String(repeating: "京", count: 30)
        let cut = WeatherCodec.truncated(long, toBytes: 63)

        #expect(cut.utf8.count <= 63)
        #expect(cut.count == 21)
        #expect(String(decoding: Array(cut.utf8), as: UTF8.self) == cut)
        #expect(WeatherCodec.truncated("Kyoto", toBytes: 63) == "Kyoto")
    }
}

@Suite
@MainActor
struct NotificationAppsTests {
    @Test func recordValueUsesTimelineAttributeLayout() {
        let app = NotificationSourceApp(
            bundleID: "com.google.Gmail",
            displayName: "Gmail",
            muteState: .never,
            muteExpiration: nil,
            stateUpdated: Date(timeIntervalSince1970: 1_745_734_125)
        )
        #expect(NotificationAppsCodec.key(for: app) == Array("com.google.Gmail".utf8))
        #expect(NotificationAppsCodec.value(for: app) == [
            0x00, 0x00, 0x00, 0x00,
            0x04, 0x00,
            30, 0x05, 0x00, 0x47, 0x6D, 0x61, 0x69, 0x6C,
            40, 0x01, 0x00, 0x00,
            14, 0x04, 0x00, 0xED, 0xC9, 0x0D, 0x68,
            50, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
    }

    @Test func anIconIsWrittenAsTheWatchsOwnResourceNumber() {
        var app = NotificationSourceApp(
            bundleID: "com.example.chat",
            displayName: "Chat",
            stateUpdated: Date(timeIntervalSince1970: 0)
        )
        app.icon = .sms

        let value = NotificationAppsCodec.value(for: app)

        #expect(value[4] == 5)
        // The high bit says the picture belongs to the system rather than to
        // an app of the watch's own.
        #expect(Array(value.suffix(7)) == [48, 0x04, 0x00, 45, 0x00, 0x00, 0x80])
    }

    @Test func decodesWatchWrittenRecord() throws {
        // Value layout captured from a real iOS ANCS write in the reference test suite.
        let value: [UInt8] = [
            0x00, 0x00, 0x00, 0x00,
            0x03, 0x00,
            30, 0x05, 0x00, 0x47, 0x6D, 0x61, 0x69, 0x6C,
            40, 0x01, 0x00, 0x7F,
            14, 0x04, 0x00, 0xED, 0xC9, 0x0D, 0x68,
        ]
        let app = try NotificationAppsCodec.decodeRecord(
            key: Array("com.google.Gmail".utf8),
            value: value,
            timestamp: 1_745_734_125
        )
        #expect(app.bundleID == "com.google.Gmail")
        #expect(app.displayName == "Gmail")
        #expect(app.muteState == .always)
        #expect(app.muteExpiration == nil)
        #expect(app.stateUpdated == Date(timeIntervalSince1970: 1_745_734_125))
    }

    @Test func unknownMuteBitmasksDegradeToNever() {
        #expect(NotificationAppMuteState(wireValue: 0x55) == .never)
        #expect(NotificationAppMuteState(wireValue: 127) == .always)
        #expect(NotificationAppMuteState(wireValue: 62) == .weekdays)
        #expect(NotificationAppMuteState(wireValue: 65) == .weekends)
    }

    @Test func insertFrameTargetsDatabaseSix() {
        let app = NotificationSourceApp(bundleID: "a.b", displayName: "AB")
        let frame = NotificationAppsCodec.insertFrame(app: app, token: 0x0102)
        #expect(frame.endpoint == 0xB1DB)
        #expect(Array(frame.payload.prefix(4)) == [0x01, 0x01, 0x02, 0x06])
        #expect(frame.payload[4] == 3)
        #expect(Array(frame.payload[5..<8]) == Array("a.b".utf8))
    }

    @Test func blobDB2WriteRoundTrip() throws {
        let key = Array("com.example.app".utf8)
        let value: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        var payload: [UInt8] = [0x08, 0xAB, 0xCD, 0x06, 0xED, 0xC9, 0x0D, 0x68]
        payload.append(UInt8(key.count))
        payload.append(contentsOf: key)
        payload.append(contentsOf: [UInt8(value.count), 0x00])
        payload.append(contentsOf: value)

        let message = try BlobDB2Codec.decode(PebbleProtocolFrame(endpoint: 0xB2DB, payload: payload))
        guard case .write(let write) = message else {
            Issue.record("Expected a write message")
            return
        }
        #expect(write.tokenBytes == [0xAB, 0xCD])
        #expect(write.databaseID == 6)
        #expect(write.timestamp == 1_745_734_125)
        #expect(write.key == key)
        #expect(write.value == value)

        let response = BlobDB2Codec.responseFrame(to: message, succeeded: true)
        #expect(response.endpoint == 0xB2DB)
        #expect(response.payload == [0x88, 0xAB, 0xCD, 0x01])
    }

    @Test func blobDB2SyncDoneIsAcknowledged() throws {
        let message = try BlobDB2Codec.decode(PebbleProtocolFrame(endpoint: 0xB2DB, payload: [0x0A, 0x11, 0x22]))
        #expect(message == .syncDone(tokenBytes: [0x11, 0x22]))
        #expect(BlobDB2Codec.responseFrame(to: message, succeeded: true).payload == [0x8A, 0x11, 0x22, 0x01])
    }

    @Test func libraryMergeKeepsNewerState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "notification-apps-\(UUID().uuidString).json")
        let library = NotificationSourceAppLibrary(fileURL: directory)
        let older = NotificationSourceApp(
            bundleID: "a.b",
            displayName: "Old",
            muteState: .always,
            stateUpdated: Date(timeIntervalSince1970: 100)
        )
        let newer = NotificationSourceApp(
            bundleID: "a.b",
            displayName: "New",
            muteState: .never,
            stateUpdated: Date(timeIntervalSince1970: 200)
        )
        _ = try await library.merge(newer)
        let merged = try await library.merge(older)
        #expect(merged.count == 1)
        #expect(merged[0].displayName == "New")
    }
}

@Suite
@MainActor
struct VoiceTests {
    private func sessionSetupPayload(includeEncoderInfo: Bool, applicationID: UUID?) -> [UInt8] {
        var attributes: [[UInt8]] = []
        if includeEncoderInfo {
            var content = Array("1.2rc1".utf8)
            content.append(contentsOf: [UInt8](repeating: 0, count: 20 - content.count))
            content.append(contentsOf: [0x80, 0x3E, 0x00, 0x00])
            content.append(contentsOf: [0x00, 0x32])
            content.append(4)
            content.append(contentsOf: [0x40, 0x01])
            attributes.append([0x01, UInt8(content.count), 0x00] + content)
        }
        if let applicationID {
            attributes.append([0x03, 16, 0x00] + BlobDBCodec.uuidBytes(applicationID))
        }
        var payload: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x34, 0x12]
        payload.append(UInt8(attributes.count))
        for attribute in attributes {
            payload.append(contentsOf: attribute)
        }
        return payload
    }

    @Test func decodesSessionSetupWithSpeexAndApplication() throws {
        let applicationID = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let request = try VoiceControlCodec.decodeSessionSetup(PebbleProtocolFrame(
            endpoint: 11_000,
            payload: sessionSetupPayload(includeEncoderInfo: true, applicationID: applicationID)
        ))
        #expect(request.sessionType == .dictation)
        #expect(request.sessionID == 0x1234)
        #expect(request.applicationID == applicationID)
        let encoderInfo = try #require(request.encoderInfo)
        #expect(encoderInfo.version == "1.2rc1")
        #expect(encoderInfo.sampleRate == 16_000)
        #expect(encoderInfo.bitRate == 0x3200)
        #expect(encoderInfo.bitstreamVersion == 4)
        #expect(encoderInfo.frameSize == 320)
    }

    @Test func sessionSetupResultUsesFlagsForAppSessions() {
        let frame = VoiceControlCodec.sessionSetupResultFrame(
            sessionType: .dictation,
            result: .disabled,
            applicationInitiated: true
        )
        #expect(frame.payload == [0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05])
    }

    @Test func dictationResultEncodesSentenceAndWords() {
        let frame = VoiceControlCodec.dictationResultFrame(
            sessionID: 0x1234,
            result: .success,
            words: [
                VoiceTranscriptionWord(text: "Hello", confidence: 1),
                VoiceTranscriptionWord(text: "World", confidence: 0.5),
            ],
            applicationID: nil
        )
        #expect(frame.payload == [
            0x02,
            0x00, 0x00, 0x00, 0x00,
            0x34, 0x12,
            0x00,
            0x01,
            0x02, 0x14, 0x00,
            0x01, 0x01,
            0x02, 0x00,
            0xFF, 0x05, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F,
            0x80, 0x05, 0x00, 0x57, 0x6F, 0x72, 0x6C, 0x64,
        ])
    }

    @Test func audioStreamDecodesDataAndStop() throws {
        let data = try AudioStreamCodec.decode(PebbleProtocolFrame(
            endpoint: 10_000,
            payload: [0x02, 0x34, 0x12, 0x03, 0xAA, 0xBB, 0xCC]
        ))
        #expect(data == .data(sessionID: 0x1234, bytes: [0xAA, 0xBB, 0xCC]))
        let stop = try AudioStreamCodec.decode(PebbleProtocolFrame(
            endpoint: 10_000,
            payload: [0x03, 0x34, 0x12]
        ))
        #expect(stop == .stop(sessionID: 0x1234))
        #expect(AudioStreamCodec.stopFrame(sessionID: 0x1234).payload == [0x03, 0x34, 0x12])
    }

    @Test func coordinatorRejectsSessionsWithoutProvider() async {
        var sent: [PebbleProtocolFrame] = []
        let collector = FrameCollector()
        let coordinator = VoiceSessionCoordinator(provider: nil) { frame in
            await collector.append(frame)
        }
        await coordinator.handleVoiceFrame(PebbleProtocolFrame(
            endpoint: 11_000,
            payload: sessionSetupPayload(includeEncoderInfo: true, applicationID: nil)
        ))
        sent = await collector.frames
        #expect(sent.count == 1)
        #expect(sent[0].payload.last == VoiceSessionResult.disabled.rawValue)
    }

    @Test func coordinatorRunsFullDictationSession() async throws {
        let collector = FrameCollector()
        let provider = StaticTranscriptionProvider(words: [VoiceTranscriptionWord(text: "Hi", confidence: 1)])
        let coordinator = VoiceSessionCoordinator(provider: provider) { frame in
            await collector.append(frame)
        }
        await coordinator.handleVoiceFrame(PebbleProtocolFrame(
            endpoint: 11_000,
            payload: sessionSetupPayload(includeEncoderInfo: true, applicationID: nil)
        ))
        var sent = await collector.frames
        #expect(sent.count == 1)
        #expect(sent[0].payload.last == VoiceSessionResult.success.rawValue)

        await coordinator.handleAudioFrame(PebbleProtocolFrame(
            endpoint: 10_000,
            payload: [0x02, 0x34, 0x12, 0x01, 0x00, 0xAB]
        ))
        await coordinator.handleAudioFrame(PebbleProtocolFrame(
            endpoint: 10_000,
            payload: [0x03, 0x34, 0x12]
        ))
        for _ in 0..<200 {
            sent = await collector.frames
            if sent.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sent.count == 2)
        #expect(sent[1].payload[0] == 0x02)
        #expect(sent[1].payload[7] == VoiceSessionResult.success.rawValue)
        let received = await provider.receivedFrames
        #expect(received == [[0x00, 0xAB]])
    }

    @Test func coordinatorReportsInvalidSetupWithoutEncoderInfo() async {
        let collector = FrameCollector()
        let coordinator = VoiceSessionCoordinator(provider: StaticTranscriptionProvider(words: [])) { frame in
            await collector.append(frame)
        }
        await coordinator.handleVoiceFrame(PebbleProtocolFrame(
            endpoint: 11_000,
            payload: sessionSetupPayload(includeEncoderInfo: false, applicationID: nil)
        ))
        let sent = await collector.frames
        #expect(sent.count == 1)
        #expect(sent[0].payload.last == VoiceSessionResult.invalidMessage.rawValue)
    }
}

private actor FrameCollector {
    private(set) var frames: [PebbleProtocolFrame] = []

    func append(_ frame: PebbleProtocolFrame) {
        frames.append(frame)
    }
}

private actor StaticTranscriptionProvider: PebbleVoiceTranscriptionProvider {
    private let words: [VoiceTranscriptionWord]
    private(set) var receivedFrames: [[UInt8]] = []

    init(words: [VoiceTranscriptionWord]) {
        self.words = words
    }

    func canServeSession() async -> Bool {
        true
    }

    func transcribe(encoderInfo: SpeexEncoderInfo, audioFrames: [[UInt8]]) async -> VoiceTranscriptionOutcome {
        receivedFrames = audioFrames
        return .transcribed(words)
    }
}
