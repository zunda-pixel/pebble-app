import Foundation
import Testing
@testable import PebbleProtocol

/// The version history a store row carries: every published version, newest
/// first, tolerant of the half-written entry and of the store's own date
/// format — fractional seconds with no zone.
@Suite
struct CatalogChangelogTests {
    private func entry(changelog: String) throws -> CatalogApplication {
        let json = """
        {
          "id": "52ce8a2a3ea",
          "uuid": "9AF9741D-28B9-4EC6-A978-F4265D988267",
          "title": "Zzz..",
          "author": "Shammamamamoo",
          "type": "watchapp",
          "latest_release": {
            "version": "1.16.0",
            "pbw_file": "https://example.com/a.pbw"
          },
          "changelog": \(changelog)
        }
        """
        let decoded = try JSONDecoder().decode(OfficialCatalogApplication.self, from: Data(json.utf8))
        return try #require(decoded.application(kind: nil))
    }

    @Test func theHistoryComesOutNewestFirstWithUTCReadIntoZonelessDates() throws {
        let application = try entry(changelog: """
        [
          {"version": "1.15.0", "published_date": "2026-01-02T03:04:05.678", "release_notes": "older"},
          {"version": "1.16.0", "published_date": "2026-09-21T01:49:41.888", "release_notes": ""},
          {"version": "1.14.0", "published_date": "2025-06-01T00:00:00Z", "release_notes": "oldest"}
        ]
        """)

        #expect(application.changelog.map(\.version) == ["1.16.0", "1.15.0", "1.14.0"])
        // The zoneless store date is the store's UTC clock, not the phone's zone.
        let expected = try Date(
            "2026-01-02T03:04:05.678Z",
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
        #expect(application.changelog[1].publishedAt == expected)
        // "" is not release notes.
        #expect(application.changelog[0].notes == nil)
        #expect(application.changelog[2].notes == "oldest")
    }

    /// One half-written entry costs itself, not the history it arrived in.
    @Test func anEntryWithoutAVersionIsDroppedAlone() throws {
        let application = try entry(changelog: """
        [
          {"version": "1.16.0", "published_date": "2026-09-21T01:49:41.888"},
          {"published_date": "2026-09-20T00:00:00.000", "release_notes": "no version"},
          {"version": "", "release_notes": "blank version"},
          {"version": "1.15.0", "published_date": "not a date", "release_notes": "kept, dateless"}
        ]
        """)

        #expect(application.changelog.map(\.version) == ["1.16.0", "1.15.0"])
        #expect(application.changelog[1].publishedAt == nil)
        #expect(application.changelog[1].notes == "kept, dateless")
    }

    /// A catalogue cached before the history was kept still opens, with none.
    @Test func aCacheWrittenBeforeTheHistoryDecodesWithNone() throws {
        let json = """
        {
          "id": "9AF9741D-28B9-4EC6-A978-F4265D988267",
          "name": "Zzz..",
          "developer": "Shammamamamoo",
          "version": "1.16.0",
          "downloadURL": "https://example.com/a.pbw",
          "supportedPlatforms": ["emery"]
        }
        """
        let decoded = try JSONDecoder().decode(CatalogApplication.self, from: Data(json.utf8))

        #expect(decoded.changelog.isEmpty)
    }
}
