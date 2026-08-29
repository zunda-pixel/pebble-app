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
