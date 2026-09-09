import Foundation
import Testing
@testable import PebbleApp

/// Which calendars reach the timeline, and how a choice survives EventKit
/// reissuing every identifier (#94).
@Suite
struct CalendarPreferenceTests {
    private let work = PhoneCalendar(id: "id-work", title: "仕事", sourceTitle: "iCloud")
    private let family = PhoneCalendar(id: "id-family", title: "家族", sourceTitle: "iCloud")
    private let holidays = PhoneCalendar(id: "id-holidays", title: "祝日", sourceTitle: "その他")

    /// A calendar nobody has touched a switch for is enabled: new calendars
    /// should appear on the watch, not vanish until somebody finds a setting.
    @Test func anUntouchedCalendarIsEnabled() {
        let enabled = CalendarPreference.enabledIdentifiers(
            of: [work, family],
            given: [CalendarPreference(
                identifier: "id-work", title: "仕事", sourceTitle: "iCloud", isEnabled: false
            )]
        )

        #expect(enabled == ["id-family"])
    }

    /// EventKit warns that a full sync can reissue `calendarIdentifier`. The
    /// choice must survive on the name and owner, and the stored row must be
    /// rewritten to the new identifier so the next lookup is exact again.
    @Test func aChoiceSurvivesAReissuedIdentifier() {
        let stored = [CalendarPreference(
            identifier: "old-id", title: "仕事", sourceTitle: "iCloud", isEnabled: false
        )]

        let enabled = CalendarPreference.enabledIdentifiers(of: [work, family], given: stored)
        #expect(enabled == ["id-family"])

        let migrated = CalendarPreference.migrated(stored, against: [work, family])
        #expect(migrated.first?.identifier == "id-work")
        #expect(migrated.first?.isEnabled == false)
    }

    /// A calendar that no longer exists keeps its row: an account signed out
    /// and back in should come back with its choices, not with everything on.
    @Test func aVanishedCalendarKeepsItsChoice() {
        let stored = [CalendarPreference(
            identifier: "id-gone", title: "旧アカウント", sourceTitle: "Google", isEnabled: false
        )]

        let migrated = CalendarPreference.migrated(stored, against: [work])

        #expect(migrated == stored)
    }

    /// Two calendars under different accounts may share a title; the owner is
    /// part of the identity or one account's choice would leak onto another's.
    @Test func theSameTitleUnderAnotherAccountIsAnotherCalendar() {
        let iCloudWork = PhoneCalendar(id: "a", title: "仕事", sourceTitle: "iCloud")
        let googleWork = PhoneCalendar(id: "b", title: "仕事", sourceTitle: "Google")
        let stored = [CalendarPreference(
            identifier: "stale", title: "仕事", sourceTitle: "Google", isEnabled: false
        )]

        let enabled = CalendarPreference.enabledIdentifiers(
            of: [iCloudWork, googleWork],
            given: stored
        )

        #expect(enabled == ["a"])
    }
}
