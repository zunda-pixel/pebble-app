import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// Who tells the watch about a call.
///
/// Not this app. On iOS the watch is told by iOS, over ANCS, with the caller's
/// name the firmware reads out of the notification — and sending the same call
/// over Pebble Protocol put the two in a race the good one could lose (#80).
/// On macOS there is no telephony to read.
@Suite
@MainActor
struct PhoneCallTests {
    /// The decision, pinned. Reintroducing a source that reports calls fails
    /// here, which is the point: the reason it was taken out is not obvious
    /// from the call site, and the cost of getting it wrong is a watch that
    /// counts the seconds of a call still ringing.
    @Test func thePhoneTellsTheWatchNothingAboutCalls() async throws {
        let source = makeSystemCallSource()
        var reported: [PhoneCallEvent] = []
        source.onEvent = { reported.append($0) }

        source.start()
        // Whatever the system is doing, nothing is offered to the watch.
        try await Task.sleep(for: .milliseconds(200))
        #expect(reported.isEmpty)

        // And an action the watch sends back is taken without complaint: iOS
        // forbids a third-party app from answering or ending a carrier call,
        // so there is nothing to do and nothing to fail.
        source.perform(.answer(cookie: 1))
        source.perform(.hangup(cookie: 1))
        #expect(reported.isEmpty)

        source.stop()
    }

    /// Nothing reaches the watch while the source says nothing, which is what
    /// makes the source the only place the decision lives.
    @Test func aSilentSourceSendsNoFrames() async throws {
        let sent = SentFrames()
        let coordinator = PhoneCallCoordinator(
            source: makeSystemCallSource(),
            send: { frame in sent.append(frame) }
        )

        coordinator.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent.frames.isEmpty)

        coordinator.stop()
    }
}

@MainActor
private final class SentFrames {
    private(set) var frames: [PebbleProtocolFrame] = []

    func append(_ frame: PebbleProtocolFrame) {
        frames.append(frame)
    }
}
