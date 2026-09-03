import Testing
@testable import PebbleProtocol

/// Which endpoints the transport carries for the app instead of answering, and
/// which it should still report when nobody was waiting.
@Suite
struct CompanionFrameTests {
    @Test
    func theEndpointsTheAppAnswersAreRecognized() {
        let recognized = [
            MusicControlCodec.endpoint,
            PhoneControlCodec.endpoint,
            VoiceControlCodec.endpoint,
            AudioStreamCodec.endpoint,
            BlobDB2Codec.endpoint,
        ]

        for endpoint in recognized {
            #expect(CompanionFrame(endpoint: endpoint)?.endpoint == endpoint)
        }
        #expect(CompanionFrame.allCases.count == recognized.count)
    }

    @Test
    func anEndpointTheTransportAnswersItselfIsNotOneOfThem() {
        // Reporting one of these as the app's would hide a reply nobody was
        // waiting for, which is the whole reason the transport logs them.
        let answeredInTheTransport = [
            PebbleProtocolFrame.metaEndpoint,
            PingPongCodec.endpoint,
            WatchVersionCodec.endpoint,
            PhoneVersionCodec.endpoint,
            PutBytesCodec.endpoint,
            BlobDBCodec.endpoint,
            ScreenshotCodec.endpoint,
            LogDumpCodec.endpoint,
            GetBytesCodec.endpoint,
        ]

        for endpoint in answeredInTheTransport {
            #expect(CompanionFrame(endpoint: endpoint) == nil)
        }
    }

    @Test
    func noTwoOfThemShareAnEndpoint() {
        let endpoints = CompanionFrame.allCases.map(\.endpoint)

        #expect(Set(endpoints).count == endpoints.count)
    }
}
