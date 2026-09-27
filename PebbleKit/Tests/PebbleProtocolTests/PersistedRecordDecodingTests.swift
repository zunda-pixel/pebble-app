import Foundation
import Testing
@testable import PebbleProtocol

/// What the stores read back from a file written before a field was added.
@Suite
struct PersistedRecordDecodingTests {
    private let id = "E3D2A5D8-6B45-4C7A-9F14-1B2C3D4E5F60"
    private let applicationID = "0863FC6A-66C5-4F62-AB8A-82ED00A98B5D"

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func aTimelinePinNeedsOnlyItsIdentityTimeAndTitle() throws {
        let pin = try decode(TimelinePin.self, """
        {"id": "\(id)", "parentApplicationID": "\(applicationID)", "timestamp": 780000000, "title": "Lunch"}
        """)

        #expect(pin.id == UUID(uuidString: id))
        #expect(pin.title == "Lunch")
        #expect(pin.durationMinutes == 0)
        #expect(pin.subtitle == nil)
        #expect(pin.body == nil)
        #expect(!pin.isAllDay)
        #expect(pin.kind == .pin)
        #expect(!pin.isFromWatch)
    }

    @Test func aTimelinePinRoundTripsEveryField() throws {
        let pin = TimelinePin(
            parentApplicationID: UUID(), timestamp: Date(timeIntervalSinceReferenceDate: 780_000_000),
            durationMinutes: 30, title: "Lunch", subtitle: "Cafe", body: "With Kim",
            isAllDay: true, kind: .reminder, isFromWatch: true
        )

        let decoded = try JSONDecoder().decode(TimelinePin.self, from: JSONEncoder().encode(pin))

        #expect(decoded == pin)
    }

    @Test func aNotificationSourceAppNeedsOnlyItsBundleAndName() throws {
        let app = try decode(NotificationSourceApp.self, """
        {"bundleID": "com.example.mail", "displayName": "Mail"}
        """)

        #expect(app.bundleID == "com.example.mail")
        #expect(app.displayName == "Mail")
        #expect(app.muteState == .never)
        #expect(app.muteExpiration == nil)
        #expect(app.icon == nil)
        #expect(app.vibePattern == nil)
        #expect(app.filterRules.isEmpty)
    }

    @Test func aFilterRuleNeedsOnlyItsIdentityAndPattern() throws {
        let rule = try decode(NotificationFilterRule.self, """
        {"id": "\(id)", "pattern": "sale"}
        """)

        #expect(rule.pattern == "sale")
        #expect(rule.field == .anywhere)
        #expect(!rule.isCaseSensitive)
    }

    @Test func aFilterRuleStillReadsItsCaseSensitivityUnderTheOldKey() throws {
        let rule = try decode(NotificationFilterRule.self, """
        {"id": "\(id)", "pattern": "sale", "field": 1, "caseSensitive": true}
        """)

        #expect(rule.field == .title)
        #expect(rule.isCaseSensitive)
    }

    @Test func anAppGlanceNeedsOnlyItsApplication() throws {
        let glance = try decode(AppGlance.self, """
        {"applicationID": "\(applicationID)", "slices": [{"id": "\(id)"}]}
        """)

        #expect(glance.applicationID == UUID(uuidString: applicationID))
        #expect(glance.slices.count == 1)
        #expect(glance.slices.first?.subtitleTemplate == "")
        #expect(glance.slices.first?.icon == nil)
        #expect(glance.slices.first?.expires == nil)
    }

    @Test func aStoredAppMessageNeedsOnlyItsIdentityApplicationAndTuples() throws {
        let message = try decode(StoredAppMessage.self, """
        {"id": "\(id)", "applicationID": "\(applicationID)", "tuples": []}
        """)

        #expect(message.applicationID == UUID(uuidString: applicationID))
        #expect(message.tuples.isEmpty)
    }

    @Test func aSentNotificationNeedsOnlyItsIdentityAndText() throws {
        let notification = try decode(SentNotification.self, """
        {"id": "\(id)", "appName": "Mail", "title": "Hello", "body": "It is me"}
        """)

        #expect(notification.appName == "Mail")
        #expect(notification.body == "It is me")
        #expect(notification.watchNames.isEmpty)
    }
}
