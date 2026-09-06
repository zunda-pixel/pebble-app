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
        for application: WatchApplication
    ) async throws -> [AppMessageTuple] {
        let sent = SentTuples()
        let runtime = PebbleCompanionRuntime(
            openURLHandler: { _ in },
            appMessageHandler: { _, tuples in sent.append(tuples) },
            notificationHandler: { _, _, _ in },
            activeWatchHandler: { nil }
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
}

/// The tuples a script sent, held where the handler can reach them.
@MainActor
private final class SentTuples {
    private(set) var tuples: [AppMessageTuple] = []

    func append(_ values: [AppMessageTuple]) {
        tuples.append(contentsOf: values)
    }
}
