#if os(macOS)
import Foundation
import Network
import PebbleProtocol
import Synchronization
import Testing
@testable import PebbleTransport
@testable import PebbleApp

/// What an emulated watch makes of this app, run only against one.
///
/// `PEBBLE_QEMU_E2E=1` turns them on, with the emulator's Pebble Protocol
/// socket on `PEBBLE_QEMU_PORT` (12344 by default). The ones that press
/// buttons need its QEMU monitor on `PEBBLE_QEMU_MONITOR_PORT`; the ones that
/// install need `PEBBLE_QEMU_PBW` and `PEBBLE_QEMU_SECOND_PBW` (emery apps, the
/// first one opening an app-message inbox and starting dictation on Select)
/// and `PEBBLE_QEMU_PBZ` (a `qemu_emery` firmware). The emulator takes one
/// connection at a time, so they run one after another, in this order: the
/// settings test expects the time source the time test leaves behind, and the
/// firmware test goes last because the watch restarts at the end of it.
@Suite(.serialized, .enabled(if: QEMUEnvironment.isEnabled))
@MainActor
struct QEMUEndToEndTests {
    @Test func connectsSynchronizesTimeAndWritesToBlobDB() async throws {
        let link = try await QEMULink.open()
        #expect(link.watch.version.firmwareVersion != nil)
        try await link.client.synchronizeTime()

        let pin = TimelinePin(
            parentApplicationID: UUID(),
            timestamp: .now.addingTimeInterval(600),
            title: "E2E pin",
            subtitle: nil,
            body: nil
        )
        try await link.client.write(.timelinePin(pin))
        // Refused unless the emulator has been told the phone claims the
        // weather app, which it never asks for.
        let place = UUID()
        try await link.client.write(.weather(WeatherReport(
            id: place,
            locationName: "E2E",
            isCurrentLocation: true,
            currentTemperature: 21,
            currentType: .sun,
            todayHigh: 24,
            todayLow: 15,
            tomorrowType: .cloudyDay,
            tomorrowHigh: 22,
            tomorrowLow: 14,
            shortPhrase: "Sunny",
            updated: .now
        )))
        try await link.client.remove(.weather(place))
        try await link.client.remove(.timelinePin(pin.id))
        await link.close()
    }

    @Test(.enabled(if: QEMUEnvironment.firstPackage != nil && QEMUEnvironment.secondPackage != nil))
    func installsApplicationsWithTheirTransfersTakingTurns() async throws {
        let link = try await QEMULink.open()
        for url in [QEMUEnvironment.firstPackage, QEMUEnvironment.secondPackage].compactMap(\.self) {
            let package = try PBWPackageImporter.load(from: url, for: .pebbleTime2)
            #expect(package.objects.count >= 2)
            try await link.install(package, forcingFetch: true)
        }
        await link.close()
    }

    /// Two BlobDB writes and an app message at once, none of them turned away
    /// for the others being in flight.
    @Test(.enabled(if: QEMUEnvironment.firstPackage != nil))
    func concurrentRequestsTakeTurnsRatherThanRefusingEachOther() async throws {
        let link = try await QEMULink.open()
        let package = try PBWPackageImporter.load(from: try #require(QEMUEnvironment.firstPackage), for: .pebbleTime2)
        try await link.install(package, forcingFetch: false)
        let applicationID = package.application.id
        let pins = (0..<2).map { index in
            TimelinePin(
                parentApplicationID: applicationID,
                timestamp: .now.addingTimeInterval(Double(900 + index * 60)),
                title: "E2E \(index)",
                subtitle: nil,
                body: nil
            )
        }
        let client = link.client

        async let first: Void = client.write(.timelinePin(pins[0]))
        async let second: Void = client.write(.timelinePin(pins[1]))
        async let message: Void = client.sendAppMessage(
            applicationID: applicationID,
            tuples: [AppMessageTuple(key: 0, value: .unsigned(1))]
        )
        _ = try await (first, second, message)

        for pin in pins { try await client.remove(.timelinePin(pin.id)) }
        await link.close()
    }

    /// The reader turning the time source back to automatic asks the phone
    /// for the time (`clock_request_time_from_phone`), and is given it.
    @Test(.enabled(if: QEMUEnvironment.monitorPort != nil))
    func theWatchAskingForTheTimeIsGivenIt() async throws {
        let link = try await QEMULink.open()
        try await link.openDateAndTime()

        // Which way the switch starts is not known, and only manual to
        // automatic asks: a second press covers a switch that was automatic.
        var request: Date?
        for _ in 0..<2 where request == nil {
            let pressed = Date()
            try await QEMUMonitor.press("right")
            request = try? await link.frameArrival(within: .seconds(3), after: pressed) {
                TimeSynchronizationCodec.isTimeRequest($0)
            }
        }
        let asked = try #require(request, "the watch never asked for the time")

        // The watch answers "what time is it" from its own clock (`0x00` and
        // `0x01`, `clock_protocol_msg_callback`), which this app's answer set.
        let queried = Date()
        try await link.client.send(PebbleProtocolFrame(endpoint: TimeSynchronizationCodec.endpoint, payload: [0x00]))
        let reply = try await link.frame(within: .seconds(3), after: queried) {
            $0.endpoint == TimeSynchronizationCodec.endpoint && $0.payload.first == 0x01
        }
        let watchTime = reply.payload.dropFirst().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(abs(Double(watchTime) - Date().timeIntervalSince1970) < 5)
        print("[qemu-e2e] time request arrived \(asked.timeIntervalSince(queried)) s before the query")
        try await QEMUMonitor.press("left", "left", "left")
        await link.close()
    }

    /// A setting changed on the watch is taken, and answered well inside the
    /// thirty seconds the watch waits before sending it again.
    @Test(.enabled(if: QEMUEnvironment.monitorPort != nil))
    func aSettingChangedOnTheWatchIsTakenPromptly() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = QEMUWatchClient(port: QEMUEnvironment.port)
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
        await QEMULink.closeTheLastOne()
        QEMULink.closeLast = { await model.disconnect() }
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        #expect(model.connectedWatch != nil)
        let wasOn = model.isWatchSettingOn(.clock24Hour)

        try await client.launchApplication(id: QEMUEnvironment.settingsApplicationID)
        try await Task.sleep(for: .seconds(1.5))
        try await QEMUMonitor.press(Array(repeating: "down", count: 6) + ["right", "down"])
        let pressed = Date()
        try await QEMUMonitor.press("right")

        var taken: Date?
        for _ in 0..<200 where taken == nil {
            if model.isWatchSettingOn(.clock24Hour) != wasOn { taken = Date() }
            try await Task.sleep(for: .milliseconds(50))
        }
        let arrival = try #require(taken, "the watch never sent the change")
        print("[qemu-e2e] clock24h changed on the watch, taken \(arrival.timeIntervalSince(pressed)) s after the press")
        #expect(arrival.timeIntervalSince(pressed) < 10)

        // Back to what it was, the same way.
        try await QEMUMonitor.press("right")
        try await QEMUMonitor.press("left", "left", "left")
        await QEMULink.closeTheLastOne()
    }

    /// A dictation session, answered once with words and once by the deadline
    /// when the recognizer never finishes.
    @Test(.enabled(if: QEMUEnvironment.monitorPort != nil && QEMUEnvironment.firstPackage != nil))
    func dictationIsAnsweredWithinTheWatchsDeadlines() async throws {
        let link = try await QEMULink.open()
        let package = try PBWPackageImporter.load(from: try #require(QEMUEnvironment.firstPackage), for: .pebbleTime2)
        try await link.install(package, forcingFetch: false)
        try await link.client.setApplicationLoggingEnabled(true)

        for provider in [
            ScriptedTranscription(words: ["hello", "emulator"]),
            ScriptedTranscription(words: nil),
        ] {
            let answers = SentFrames()
            let coordinator = VoiceSessionCoordinator(provider: provider) { [client = link.client] frame in
                answers.append(frame)
                try await client.send(frame)
            }
            link.onFrame = { frame in
                switch CompanionFrame(endpoint: frame.endpoint) {
                case .voiceControl: await coordinator.handleVoiceFrame(frame)
                case .audioStream: await coordinator.handleAudioFrame(frame)
                default: break
                }
            }
            // The app ignores a press in the moment after it starts, and the
            // dictation window a moment after it closes.
            try await Task.sleep(for: .seconds(2))
            let pressed = Date()
            try await QEMUMonitor.press("right")
            let setup = try await link.frameArrival(within: .seconds(8), after: pressed) {
                $0.endpoint == VoiceControlCodec.endpoint
            }
            try await Task.sleep(for: .seconds(2))
            try await QEMUMonitor.press("right")
            let stopped = try await link.frameArrival(within: .seconds(8), after: setup) {
                $0.endpoint == AudioStreamCodec.endpoint && $0.payload.first == 0x03
            }
            for _ in 0..<400 where answers.result == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            let result = try #require(answers.result, "no result was sent")
            let answeredAfter = result.date.timeIntervalSince(stopped)
            print("[qemu-e2e] dictation (\(provider.words == nil ? "stalled" : "answered")): "
                + "setup \(setup.timeIntervalSince(pressed)) s after the press, "
                + "result \(answeredAfter) s after recording stopped")
            #expect(answeredAfter < 15)
            if provider.words != nil {
                let line = try await link.applicationLog(within: .seconds(5), after: stopped) {
                    $0.contains("e2e dictation status=")
                }
                #expect(line.text.contains("status=0 text=hello emulator"))
            } else {
                #expect(result.frame.payload[7] == VoiceSessionResult.timeout.rawValue)
            }
        }
        // The dictation window tries again by itself after a failure. Turned
        // away rather than left unanswered, so that it gives up and Back
        // leaves it, instead of the watch streaming audio into the next test.
        let refusal = VoiceSessionCoordinator(provider: nil) { [client = link.client] frame in
            try await client.send(frame)
        }
        link.onFrame = { frame in
            if CompanionFrame(endpoint: frame.endpoint) == .voiceControl {
                await refusal.handleVoiceFrame(frame)
            }
        }
        for _ in 0..<2 {
            try await Task.sleep(for: .seconds(2))
            try await QEMUMonitor.press("left")
        }
        try await Task.sleep(for: .seconds(2))
        link.onFrame = nil
        await link.close()
    }

    /// The install is answered with a cookie of zero, and the transport takes
    /// it (#10).
    @Test(.enabled(if: QEMUEnvironment.firmwarePackage != nil))
    func installsFirmware() async throws {
        let link = try await QEMULink.open()
        let package = try PBZFirmwareImporter.load(
            from: try #require(QEMUEnvironment.firmwarePackage),
            board: .qemuEmery
        )
        try await link.client.installFirmware(package)
        await link.close()
    }
}

enum QEMUEnvironment {
    private static var values: [String: String] { ProcessInfo.processInfo.environment }

    static var isEnabled: Bool { values["PEBBLE_QEMU_E2E"] == "1" }
    static var port: UInt16 { values["PEBBLE_QEMU_PORT"].flatMap(UInt16.init) ?? 12_344 }
    static var monitorPort: UInt16? { values["PEBBLE_QEMU_MONITOR_PORT"].flatMap(UInt16.init) }
    static var firstPackage: URL? { values["PEBBLE_QEMU_PBW"].map { URL(filePath: $0) } }
    static var secondPackage: URL? { values["PEBBLE_QEMU_SECOND_PBW"].map { URL(filePath: $0) } }
    static var firmwarePackage: URL? { values["PEBBLE_QEMU_PBZ"].map { URL(filePath: $0) } }
    /// The firmware's own Settings app, as `app_run_state` names it.
    static let settingsApplicationID = UUID(uuidString: "07E0D9CB-8957-4BF7-9D42-35BF47CAADFE")!
}

/// One connection to the emulator, and everything it said, timestamped.
@MainActor
final class QEMULink {
    let client: QEMUWatchClient
    private(set) var watch: ConnectedWatch
    private(set) var events: [(date: Date, event: WatchClientEvent)] = []
    private(set) var frames: [(date: Date, frame: PebbleProtocolFrame)] = []
    var onFrame: ((PebbleProtocolFrame) async -> Void)?
    private var tasks: [Task<Void, Never>] = []

    private init(client: QEMUWatchClient, watch: ConnectedWatch) {
        self.client = client
        self.watch = watch
    }

    /// Whatever the last test left connected. The emulator serves one
    /// connection at a time, so a test that stopped at a failed expectation
    /// before closing its own would otherwise fail every test after it.
    static var closeLast: (() async -> Void)?

    static func closeTheLastOne() async {
        let close = closeLast
        closeLast = nil
        await close?()
    }

    static func open() async throws -> QEMULink {
        await closeTheLastOne()
        let client = QEMUWatchClient(port: QEMUEnvironment.port)
        let events = client.events()
        let frames = client.frames()
        let watch = try await client.connect(to: try #require(try await client.scan().first))
        let link = QEMULink(client: client, watch: watch)
        closeLast = { await link.close() }
        link.tasks.append(Task { [weak link] in
            for await event in events { link?.events.append((Date(), event)) }
        })
        link.tasks.append(Task { [weak link] in
            for await frame in frames {
                link?.frames.append((Date(), frame))
                // Taken, as the app would take it. The watch syncs one record
                // at a time and resends it every thirty seconds until it is
                // answered (`services/blob_db/sync.c`), so one left unanswered
                // here holds up every setting changed in the tests after.
                if let message = try? BlobDB2Codec.decode(frame) {
                    try? await client.send(BlobDB2Codec.responseFrame(to: message, succeeded: true))
                }
                await link?.onFrame?(frame)
            }
        })
        return link
    }

    func close() async {
        guard !tasks.isEmpty else { return }
        await client.disconnect(from: watch)
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    func frame(
        within timeout: Duration,
        after start: Date,
        where matches: (PebbleProtocolFrame) -> Bool
    ) async throws -> PebbleProtocolFrame {
        try await first(within: timeout) {
            frames.first { $0.date >= start && matches($0.frame) }?.frame
        }
    }

    func frameArrival(
        within timeout: Duration,
        after start: Date,
        where matches: (PebbleProtocolFrame) -> Bool
    ) async throws -> Date {
        try await first(within: timeout) {
            frames.first { $0.date >= start && matches($0.frame) }?.date
        }
    }

    func event<Value>(
        within timeout: Duration,
        after start: Date,
        _ match: (WatchClientEvent) -> Value?
    ) async throws -> Value {
        try await first(within: timeout) {
            for entry in events where entry.date >= start {
                if let value = match(entry.event) { return value }
            }
            return nil
        }
    }

    func applicationLog(
        within timeout: Duration,
        after start: Date,
        where matches: (String) -> Bool
    ) async throws -> (date: Date, text: String) {
        try await first(within: timeout) {
            for entry in events where entry.date >= start {
                if case .applicationLogReceived(let line) = entry.event, matches(line.line.message) {
                    return (entry.date, line.line.message)
                }
            }
            return nil
        }
    }

    /// Registers, launches and — when the watch asks for it — sends the app,
    /// all its objects at once so that the transport has to queue them.
    func install(_ package: PBWPackage, forcingFetch: Bool) async throws {
        let applicationID = package.application.id
        if forcingFetch {
            try await client.remove(.application(applicationID))
        }
        try await client.write(.application(package.appMetadata))
        let launched = Date()
        try await client.launchApplication(id: applicationID)
        let fetch: AppFetchRequest? = try? await event(within: .seconds(10), after: launched) {
            if case .appFetchRequested(let request) = $0, request.applicationID == applicationID { request } else { nil }
        }
        if forcingFetch { #expect(fetch != nil) }
        if let fetch {
            try await client.respondToAppFetch(with: .start)
            let transfers = package.objects.map { object in
                Task {
                    try await client.installApplicationObject(
                        [UInt8](object.data),
                        objectType: object.installationObject.objectType,
                        appBankID: fetch.appBankID
                    )
                }
            }
            for transfer in transfers { try await transfer.value }
        }
        let started: Bool = try await event(within: .seconds(15), after: launched) {
            if case .appRunStateChanged(.started(applicationID)) = $0 { true } else { nil }
        }
        #expect(started)
    }

    /// Settings, then Date & Time: the seventh of its categories
    /// (`SettingsMenuItemDateTime`, `apps/system/settings/menu.h`).
    func openDateAndTime() async throws {
        try await client.launchApplication(id: QEMUEnvironment.settingsApplicationID)
        try await Task.sleep(for: .seconds(1.5))
        try await QEMUMonitor.press(Array(repeating: "down", count: 6) + ["right"])
        try await Task.sleep(for: .seconds(1))
    }

    private func first<Value>(within timeout: Duration, _ look: () -> Value?) async throws -> Value {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = look() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let value = look() { return value }
        throw QEMUEndToEndError.timedOut
    }
}

enum QEMUEndToEndError: Error {
    case timedOut
    case noMonitor
}

/// Presses the emulator's buttons through its QEMU monitor: the arrow keys
/// are the watch's, with right for Select and left for Back.
enum QEMUMonitor {
    static func press(_ keys: String...) async throws {
        try await press(keys)
    }

    static func press(_ keys: [String]) async throws {
        guard let port = QEMUEnvironment.monitorPort.flatMap(NWEndpoint.Port.init(rawValue:)) else {
            throw QEMUEndToEndError.noMonitor
        }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let answered = Mutex(false)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, any Error>
                switch state {
                case .ready: result = .success(())
                case .failed(let error), .waiting(let error): result = .failure(error)
                default: return
                }
                let already = answered.withLock { answered in
                    defer { answered = true }
                    return answered
                }
                if !already { continuation.resume(with: result) }
            }
            connection.start(queue: .global())
        }
        for key in keys {
            connection.send(content: Data("sendkey \(key)\n".utf8), completion: .idempotent)
            try await Task.sleep(for: .milliseconds(400))
        }
        connection.cancel()
    }
}

/// What the coordinator said, and when.
@MainActor
private final class SentFrames {
    private(set) var frames: [(date: Date, frame: PebbleProtocolFrame)] = []

    /// The dictation result, as distinct from the answer to the setup.
    var result: (date: Date, frame: PebbleProtocolFrame)? {
        frames.first { $0.frame.payload.first == 0x02 }
    }

    func append(_ frame: PebbleProtocolFrame) {
        frames.append((Date(), frame))
    }
}

/// Words handed back at once, or never.
private struct ScriptedTranscription: VoiceTranscriptionProvider {
    let words: [String]?

    func canServeSession(_ sessionType: VoiceSessionType) async -> Bool { true }

    func transcribe(encoderInfo: SpeexEncoderInfo, audioFrames: [[UInt8]]) async -> VoiceTranscriptionOutcome {
        guard let words else {
            try? await Task.sleep(for: .seconds(60))
            return .failed(.recognizerError)
        }
        return .transcribed(words.map { VoiceTranscriptionWord(text: $0, confidence: 1) })
    }
}
#endif
