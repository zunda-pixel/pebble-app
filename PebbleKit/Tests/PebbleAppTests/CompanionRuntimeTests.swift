import CoreLocation
import Foundation
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
            versionCode: 1,
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
        }
    ) async throws -> [AppMessageTuple] {
        let sent = SentTuples()
        let runtime = PebbleCompanionRuntime(
            openURLHandler: { _ in },
            appMessageHandler: { _, tuples in sent.append(tuples) },
            notificationHandler: { _, _, _ in },
            activeWatchHandler: { nil },
            locationHandler: position
        )
        try await runtime.load(source: script, application: application)
        // `ready` is dispatched by the load, and the script answers on the
        // handler above; the round trip is through a web view either way.
        for _ in 0..<40 where sent.tuples.isEmpty {
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

    /// `watchPosition` answers once and hands back a token `clearWatch` takes.
    ///
    /// A script that watches gets its first fix; it does not get refreshes,
    /// which is what the app has to offer and is worth being plain about.
    ///
    /// Both ways round in one test on purpose: that nothing arrives after
    /// `clearWatch` means nothing on its own — it is also what a shim that
    /// never worked would do. The pair differs by that one call.
    @Test func aScriptWatchingIsAnsweredOnceAndCanStop() async throws {
        let watching = UUID()
        let cleared = UUID()
        defer {
            Task {
                await PebbleCompanionRuntime.forget(applicationID: watching)
                await PebbleCompanionRuntime.forget(applicationID: cleared)
            }
        }
        let position = { CLLocation(latitude: 1.5, longitude: 2.5) }

        let answered = try await run(
            """
            Pebble.addEventListener('ready', function () {
              var token = navigator.geolocation.watchPosition(function (p) {
                Pebble.sendAppMessage({kept: 'token ' + (token > 0) + ' at ' + p.coords.latitude.toFixed(1)});
              });
            });
            """,
            for: makeApplication(id: watching),
            answeringPositionWith: position
        )
        #expect(answered.first?.value == .string("token true at 1.5"))

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
            answeringPositionWith: position
        )
        #expect(stopped.isEmpty)
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
