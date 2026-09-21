import CoreLocation
import Foundation
import Network
import Synchronization
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// What an application's own JavaScript is given to work with.
///
/// The script is the application's, so what it can reach decides whether the
/// application works at all: the ones that matter keep their settings in
/// `localStorage` and read someone else's JSON over the network.
@Suite
@MainActor
struct CompanionRuntimeTests {
    private func makeApplication(id: UUID) -> WatchApplication {
        WatchApplication(
            id: id,
            shortName: "Keeper",
            longName: "Keeper",
            companyName: "nobody",
            versionLabel: "1.0",
            capabilities: ["configurable"],
            targetPlatforms: ["emery"],
            kind: .watchapp,
            appKeys: ["kept": 1],
            hasCompanionJavaScript: true
        )
    }

    /// A script that runs, keeps something, and is asked for it again by a
    /// second runtime — which is what the next launch is.
    ///
    /// The store was `.nonPersistent()`, which is memory: an application that
    /// kept its settings the usual way was set up again every launch, and
    /// nothing said so. Two runtimes rather than two launches, because that is
    /// the same question a test can ask.
    private func run(
        _ script: String,
        for application: WatchApplication,
        answeringPositionWith position: @escaping () async throws -> CLLocation = {
            throw WeatherSourceError.locationNotAllowed
        },
        watchingPositionsWith updates: @escaping @MainActor () throws -> AsyncThrowingStream<CLLocation, any Error> = {
            throw WeatherSourceError.locationNotAllowed
        },
        untilSent: Int = 1
    ) async throws -> [AppMessageTuple] {
        let sent = SentTuples()
        let runtime = PebbleCompanionRuntime(
            openURLHandler: { _ in },
            appMessageHandler: { _, tuples in sent.append(tuples) },
            notificationHandler: { _, _, _ in },
            activeWatchHandler: { nil },
            locationHandler: position,
            locationUpdatesHandler: updates
        )
        try await runtime.load(source: script, application: application)
        // `ready` is dispatched by the load, and the script answers on the
        // handler above; the round trip is through a web view either way.
        for _ in 0..<40 where sent.tuples.count < untilSent {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return sent.tuples
    }

    @Test func aScriptKeepsWhatItStoredForTheNextLaunch() async throws {
        let id = UUID()
        let application = makeApplication(id: id)
        defer { Task { await PebbleCompanionRuntime.forget(applicationID: id) } }

        // First launch: keep something.
        let kept = try await run(
            """
            Pebble.addEventListener('ready', function () {
              localStorage.setItem('greeting', 'hello');
              Pebble.sendAppMessage({kept: localStorage.getItem('greeting') || 'nothing'});
            });
            """,
            for: application
        )
        #expect(kept.first?.value == .string("hello"))

        // Second launch: the same application, a runtime that has just been made.
        let read = try await run(
            """
            Pebble.addEventListener('ready', function () {
              Pebble.sendAppMessage({kept: localStorage.getItem('greeting') || 'nothing'});
            });
            """,
            for: application
        )
        #expect(read.first?.value == .string("hello"))
    }

    /// One application's settings are not another's. They share an origin
    /// scheme and differ only by identifier, which is what the per-application
    /// store is keyed on.
    @Test func oneApplicationsSettingsAreNotAnothers() async throws {
        let mine = UUID()
        let theirs = UUID()
        defer {
            Task {
                await PebbleCompanionRuntime.forget(applicationID: mine)
                await PebbleCompanionRuntime.forget(applicationID: theirs)
            }
        }

        let keep = """
        Pebble.addEventListener('ready', function () {
          localStorage.setItem('greeting', 'mine');
          Pebble.sendAppMessage({kept: 'done'});
        });
        """
        _ = try await run(keep, for: makeApplication(id: mine))

        let look = """
        Pebble.addEventListener('ready', function () {
          Pebble.sendAppMessage({kept: localStorage.getItem('greeting') || 'nothing'});
        });
        """
        let seen = try await run(look, for: makeApplication(id: theirs))
        #expect(seen.first?.value == .string("nothing"))
    }

    /// A script asking where it is.
    ///
    /// `navigator.geolocation` is in the web view and answers nothing — eight
    /// seconds and not even an error, because WebKit has no public way for an
    /// app to grant it: `WKUIDelegate` and `WebPage.DeviceSensorAuthorization`
    /// between them offer `deviceOrientationAndMotion` and `mediaCapture` and
    /// no more. So it is replaced, and the shape has to be the web's or a
    /// script written against a browser reads the wrong fields.
    @Test func aScriptIsToldWhereItIs() async throws {
        let id = UUID()
        defer { Task { await PebbleCompanionRuntime.forget(applicationID: id) } }

        let answered = try await run(
            """
            Pebble.addEventListener('ready', function () {
              navigator.geolocation.getCurrentPosition(function (p) {
                Pebble.sendAppMessage({kept: p.coords.latitude.toFixed(2) + ',' + p.coords.longitude.toFixed(2)});
              }, function (e) {
                Pebble.sendAppMessage({kept: 'error ' + e.code});
              });
            });
            """,
            for: makeApplication(id: id),
            answeringPositionWith: {
                CLLocation(latitude: 35.68, longitude: 139.77)
            }
        )
        #expect(answered.first?.value == .string("35.68,139.77"))
    }

    /// And one asking where it is when the reader has not said.
    ///
    /// The failure callback rather than silence, with the web's own code:
    /// `1` is refused, which is the one the reader can do something about.
    @Test func aScriptIsToldWhenThePositionIsRefused() async throws {
        let id = UUID()
        defer { Task { await PebbleCompanionRuntime.forget(applicationID: id) } }

        let answered = try await run(
            """
            Pebble.addEventListener('ready', function () {
              navigator.geolocation.getCurrentPosition(function () {
                Pebble.sendAppMessage({kept: 'somehow got one'});
              }, function (e) {
                Pebble.sendAppMessage({kept: 'code ' + e.code + ' ' + (e.message.length > 0)});
              });
            });
            """,
            for: makeApplication(id: id)
        )
        #expect(answered.first?.value == .string("code 1 true"))
    }

    /// A script's request is answered across origins: PKJS scripts were
    /// written for a runtime without the web's same-origin rules, and the
    /// services they call offer no CORS headers to a pebble.local origin —
    /// through WebKit's own XMLHttpRequest this exact request died silently
    /// (#129). The server here shares no origin with the page and sends no
    /// CORS header, which is the situation being fixed.
    @Test func aScriptsRequestIsAnsweredWithoutTheWebsOriginRules() async throws {
        let server = MiniHTTPServer(responseBody: #"{"answer": 42}"#)
        let port = try await server.start()
        defer { server.stop() }
        let id = UUID()
        defer { Task { await PebbleCompanionRuntime.forget(applicationID: id) } }

        let answered = try await run(
            """
            Pebble.addEventListener('ready', function () {
              var req = new XMLHttpRequest();
              req.open('GET', 'http://127.0.0.1:\(port)/answer', true);
              req.onload = function () {
                var parsed = JSON.parse(req.responseText);
                Pebble.sendAppMessage({kept: 'status ' + req.status + ' answer ' + parsed.answer});
              };
              req.onerror = function () { Pebble.sendAppMessage({kept: 'error'}); };
              req.send(null);
            });
            """,
            for: makeApplication(id: id)
        )

        #expect(answered.first?.value == .string("status 200 answer 42"))
    }

    /// A payload off the watch reads under both spellings: the name the
    /// appKeys declare, which is how the SDK's own samples read it, and the
    /// number, which is how the older scripts do. Numbers alone left every
    /// name-reading script deaf to the watch (#128).
    @Test func aPayloadOffTheWatchAnswersToItsNameAndItsNumber() async throws {
        let id = UUID()
        let application = makeApplication(id: id)
        defer { Task { await PebbleCompanionRuntime.forget(applicationID: id) } }
        let sent = SentTuples()
        let runtime = PebbleCompanionRuntime(
            openURLHandler: { _ in },
            appMessageHandler: { _, tuples in sent.append(tuples) },
            notificationHandler: { _, _, _ in },
            activeWatchHandler: { nil },
            locationHandler: { throw WeatherSourceError.locationNotAllowed }
        )
        try await runtime.load(
            source: """
            Pebble.addEventListener('appmessage', function (e) {
              Pebble.sendAppMessage({kept: 'name ' + e.payload.kept + ' number ' + e.payload[1]});
            });
            """,
            application: application
        )

        try await runtime.deliver(AppMessageData(
            transactionID: 1,
            applicationID: id,
            tuples: [AppMessageTuple(key: 1, value: .string("hello"))]
        ))

        for _ in 0..<40 where sent.tuples.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(sent.tuples.first?.value == .string("name hello number hello"))
    }

    /// `watchPosition` follows the phone: every fix lands in the same callback
    /// until `clearWatch` takes the token back (#90).
    ///
    /// Both ways round in one test on purpose: that nothing arrives after
    /// `clearWatch` means nothing on its own — it is also what a shim that
    /// never worked would do. The pair differs by that one call.
    @Test func aScriptWatchingIsFollowedUntilItStops() async throws {
        let watching = UUID()
        let cleared = UUID()
        defer {
            Task {
                await PebbleCompanionRuntime.forget(applicationID: watching)
                await PebbleCompanionRuntime.forget(applicationID: cleared)
            }
        }
        // Two fixes and then an open line, which is what a live watch is.
        let fixes: @MainActor () throws -> AsyncThrowingStream<CLLocation, any Error> = {
            AsyncThrowingStream { continuation in
                continuation.yield(CLLocation(latitude: 1.5, longitude: 2.5))
                continuation.yield(CLLocation(latitude: 3.5, longitude: 2.5))
            }
        }

        let answered = try await run(
            """
            Pebble.addEventListener('ready', function () {
              var token = navigator.geolocation.watchPosition(function (p) {
                Pebble.sendAppMessage({kept: 'token ' + (token > 0) + ' at ' + p.coords.latitude.toFixed(1)});
              });
            });
            """,
            for: makeApplication(id: watching),
            watchingPositionsWith: fixes,
            untilSent: 2
        )
        #expect(answered.map(\.value) == [.string("token true at 1.5"), .string("token true at 3.5")])

        let stopped = try await run(
            """
            Pebble.addEventListener('ready', function () {
              var token = navigator.geolocation.watchPosition(function (p) {
                Pebble.sendAppMessage({kept: 'should not arrive'});
              });
              navigator.geolocation.clearWatch(token);
            });
            """,
            for: makeApplication(id: cleared),
            watchingPositionsWith: fixes
        )
        #expect(stopped.isEmpty)
    }
}

/// One HTTP answer on a loopback port, for proving the shim's requests reach
/// past the page's origin. It reads the request only to know one arrived; the
/// answer is fixed.
private final class MiniHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mini-http-server")

    init(responseBody: String) {
        listener = try! NWListener(using: .tcp, on: .any)
        let response = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(responseBody.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + responseBody
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            // The listener may pass through ready and then fail; the
            // continuation is owed exactly one answer.
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { [listener] state in
                let alreadyAnswered = resumed.withLock { answered in
                    let was = answered
                    if state == .ready || state.isFailure { answered = true }
                    return was
                }
                guard !alreadyAnswered else { return }
                switch state {
                case .ready:
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

private extension NWListener.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The tuples a script sent, held where the handler can reach them.
@MainActor
private final class SentTuples {
    private(set) var tuples: [AppMessageTuple] = []

    func append(_ values: [AppMessageTuple]) {
        tuples.append(contentsOf: values)
    }
}
