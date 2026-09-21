import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// The slices `Pebble.appGlanceReload` takes, read into this app's glances.
@Suite
struct CompanionAppGlanceTests {
    @Test func aSliceIsReadWholeIconAndAll() throws {
        let slices = try CompanionAppGlance.slices(from: """
        [{
          "layout": {
            "icon": "system://images/TIMELINE_WEATHER",
            "subtitleTemplateString": "Sunny, 23°C"
          },
          "expirationTime": "2026-09-22T00:00:00Z"
        }]
        """)

        let slice = try #require(slices.first)
        #expect(slice.subtitleTemplate == "Sunny, 23°C")
        #expect(slice.icon == .weather)
        #expect(slice.expires == (try Date("2026-09-22T00:00:00Z", strategy: .iso8601)))
    }

    /// An icon this app cannot name costs the icon alone, not the slice: nil
    /// leaves the watch the app's own icon, the same answer the editor gives.
    @Test func anUnknownIconLeavesTheWatchTheAppsOwn() throws {
        let slices = try CompanionAppGlance.slices(from: """
        [{"layout": {"icon": "system://images/NO_SUCH_ICON", "subtitleTemplateString": "still here"}}]
        """)

        #expect(slices.first?.icon == nil)
        #expect(slices.first?.subtitleTemplate == "still here")
        #expect(slices.first?.expires == nil)
    }

    /// The documented way to take the glance down.
    @Test func anEmptyListIsNoSlices() throws {
        #expect(try CompanionAppGlance.slices(from: "[]").isEmpty)
    }

    @Test func whatCannotBeAGlanceIsRefusedByName() {
        #expect(throws: CompanionAppGlance.ParseError.unreadable) {
            try CompanionAppGlance.slices(from: "not json")
        }
        #expect(throws: CompanionAppGlance.ParseError.notAList) {
            try CompanionAppGlance.slices(from: #"{"layout": {}}"#)
        }
        #expect(throws: CompanionAppGlance.ParseError.sliceWithoutALayout) {
            try CompanionAppGlance.slices(from: #"[{"expirationTime": "2026-09-22T00:00:00Z"}]"#)
        }
        // One more than the watch keeps (APP_GLANCE_DB_MAX_SLICES_PER_GLANCE):
        // refused rather than silently trimmed, so the author finds out.
        let nine = "[" + Array(repeating: #"{"layout": {"subtitleTemplateString": "s"}}"#, count: 9)
            .joined(separator: ",") + "]"
        #expect(throws: CompanionAppGlance.ParseError.tooManySlices) {
            try CompanionAppGlance.slices(from: nine)
        }
    }
}
