import Foundation
import PebbleProtocol
import Testing
@testable import PebbleTransport

/// What both transports now share, held to it over a link that is only a list
/// of the frames put on it.
@Suite
@MainActor
struct WatchSessionTests {
    @Test func aPingIsAnsweredOnTheSpot() throws {
        let link = FakeLink()

        let answered = try link.session.answer(PingPongCodec.frame(for: .ping(cookie: 7)))

        #expect(answered)
        #expect(link.sent == [PingPongCodec.frame(for: .pong(cookie: 7))])
    }

    @Test func thePhonesVersionIsAnsweredWithItsOwnSystem() throws {
        let link = FakeLink(operatingSystem: .macOS)
        let request = PebbleProtocolFrame(endpoint: PhoneVersionCodec.endpoint, payload: [0x00])
        #expect(PhoneVersionCodec.isRequest(request))

        _ = try link.session.answer(request)

        #expect(link.sent == [PhoneVersionCodec.responseFrame(operatingSystem: .macOS)])
    }

    @Test func aWriteFinishesWhenTheWatchSaysYes() async throws {
        let link = FakeLink()
        let write = Task { try await link.session.write(.notification(Self.notification)) }
        let token = try await link.blobDBToken()

        _ = try link.session.answer(Self.blobDBResponse(token: token, status: .success))

        try await write.value
    }

    @Test func aWriteTheWatchRefusesSaysWhy() async throws {
        let link = FakeLink()
        let write = Task { try await link.session.write(.notification(Self.notification)) }
        let token = try await link.blobDBToken()

        _ = try link.session.answer(Self.blobDBResponse(token: token, status: .databaseFull))

        await #expect(throws: BlobDBClientError.rejected(.databaseFull)) { try await write.value }
    }

    @Test func aReplyThatCannotBeReadEndsTheWriteWaitingForIt() async throws {
        let link = FakeLink()
        let write = Task { try await link.session.write(.notification(Self.notification)) }
        _ = try await link.blobDBToken()

        #expect(throws: BlobDBCodecError.invalidPayload) {
            try link.session.answer(PebbleProtocolFrame(endpoint: BlobDBCodec.endpoint, payload: [0x00]))
        }

        await #expect(throws: BlobDBCodecError.invalidPayload) { try await write.value }
    }

    /// The emulator's client used to fail the phone's message over this.
    @Test func anAppMessageThatCannotBeReadFailsNoMessageWaiting() async throws {
        let link = FakeLink()
        let send = Task { try await link.session.sendAppMessage(applicationID: UUID(), tuples: []) }
        try await link.waitUntil { !$0.sent.isEmpty }

        _ = try link.session.answer(PebbleProtocolFrame(endpoint: AppMessageCodec.endpoint, payload: [0x01]))
        _ = try link.session.answer(AppMessageCodec.resultFrame(transactionID: 0, acknowledged: true))

        try await send.value
    }

    @Test func aLinkThatEndsFailsTheWriteInFlightAndTheOnesQueuedBehindIt() async throws {
        let link = FakeLink()
        let first = Task { try await link.session.write(.notification(Self.notification)) }
        _ = try await link.blobDBToken()
        let second = Task { try await link.session.write(.notification(Self.notification)) }
        await Task.yield()

        link.session.failWorkInFlight(WatchConnectionError.disconnected)

        await #expect(throws: WatchConnectionError.disconnected) { try await first.value }
        await #expect(throws: WatchConnectionError.disconnected) { try await second.value }
        #expect(link.sent.filter { $0.endpoint == BlobDBCodec.endpoint }.count == 1)
    }

    /// Both transports pull now; the emulator's used to say it could not.
    @Test func aPullAsksTheWatchOverTheLink() async throws {
        let link = FakeLink()
        let pull = Task { try await link.session.pull(.screenshot) }
        try await link.waitUntil { !$0.sent.isEmpty }

        #expect(link.sent == [ScreenshotCodec.requestFrame()])
        link.session.failWorkInFlight(WatchConnectionError.disconnected)
        await #expect(throws: WatchConnectionError.disconnected) { try await pull.value }
    }

    /// The emulator's client used to answer this with `invalidConfiguration`.
    @Test func aFileIsSentUnderItsName() async throws {
        let link = FakeLink()
        let bytes: [UInt8] = [1, 2, 3, 4]
        let install = Task { try await link.session.installFile(bytes, filename: "lang") }
        try await link.waitUntil { !$0.sent.isEmpty }

        #expect(link.sent.first == (try PutBytesCodec.fileInitializationFrame(objectSize: 4, filename: "lang")))
        link.session.failWorkInFlight(WatchConnectionError.disconnected)
        await #expect(throws: WatchConnectionError.disconnected) { try await install.value }
    }

    @Test func nothingIsAskedOfALinkThatIsDown() async throws {
        let link = FakeLink()
        link.isUp = false

        await #expect(throws: WatchConnectionError.disconnected) {
            try await link.session.write(.notification(Self.notification))
        }
        await #expect(throws: WatchConnectionError.disconnected) {
            try await link.session.sendAppMessage(applicationID: UUID(), tuples: [])
        }
        #expect(link.sent.isEmpty)
    }

    @Test func aTransferIsSaidToBeUnderWayUntilItEnds() async throws {
        let link = FakeLink()
        #expect(!link.session.isTransferring)
        let install = Task { try await link.session.installApplicationObject([1], objectType: .appExecutable, appBankID: 0) }
        try await link.waitUntil { !$0.sent.isEmpty }

        #expect(link.session.isTransferring)
        link.session.failWorkInFlight(WatchConnectionError.disconnected)
        _ = try? await install.value
        #expect(!link.session.isTransferring)
    }

    private static let notification = TimelineNotification(
        parentApplicationID: UUID(),
        title: "Hello",
        body: "There",
        appName: "Chat"
    )

    private static func blobDBResponse(token: UInt16, status: BlobDBStatus) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: BlobDBCodec.endpoint,
            payload: [UInt8(token >> 8), UInt8(token & 0xFF), status.rawValue]
        )
    }
}

@MainActor
private final class FakeLink {
    var isUp = true
    private(set) var sent: [PebbleProtocolFrame] = []
    private(set) var events: [WatchClientEvent] = []
    let operatingSystem: PhoneOperatingSystem

    init(operatingSystem: PhoneOperatingSystem = .iOS) {
        self.operatingSystem = operatingSystem
    }

    lazy var session = WatchSession(
        tag: "test",
        operatingSystem: operatingSystem,
        isLinked: { [unowned self] in isUp },
        send: { [unowned self] frame in
            guard isUp else { throw WatchConnectionError.disconnected }
            sent.append(frame)
        },
        report: { [unowned self] event in events.append(event) }
    )

    /// Lets the tasks the test started run until `condition` holds.
    func waitUntil(_ condition: (FakeLink) -> Bool) async throws {
        for _ in 0..<1_000 where !condition(self) {
            await Task.yield()
        }
        try #require(condition(self))
    }

    /// The token of the BlobDB write last put on the link, once one is.
    func blobDBToken() async throws -> UInt16 {
        try await waitUntil { $0.sent.contains { $0.endpoint == BlobDBCodec.endpoint } }
        let frame = try #require(sent.last { $0.endpoint == BlobDBCodec.endpoint })
        return UInt16(frame.payload[1]) << 8 | UInt16(frame.payload[2])
    }
}
