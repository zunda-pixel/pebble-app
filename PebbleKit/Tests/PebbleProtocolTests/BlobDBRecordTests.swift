import Foundation
import Testing
@testable import PebbleProtocol

/// The frames and the accepted statuses that used to be written out in each
/// transport, asserted against what the record now produces.
///
/// Every expectation here was read off `CoreBluetoothWatchClient` before its
/// twenty typed methods were deleted: that client is the one verified against a
/// real watch, so where the emulator disagreed with it the emulator was wrong.
@Suite
struct BlobDBRecordTests {
    private let applicationID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private let itemID = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!
    private let timestamp = Date(timeIntervalSince1970: 1_788_393_600)

    private var metadata: ApplicationMetadata {
        ApplicationMetadata(
            applicationID: applicationID,
            flags: 0,
            iconResourceID: 0,
            appVersionMajor: 1,
            appVersionMinor: 0,
            sdkVersionMajor: 5,
            sdkVersionMinor: 0,
            name: "Sample"
        )
    }

    private var pin: TimelinePin {
        TimelinePin(
            id: itemID,
            parentApplicationID: applicationID,
            timestamp: timestamp,
            title: "Stand up",
            subtitle: "Two minutes",
            body: nil
        )
    }

    private var notification: TimelineNotification {
        TimelineNotification(
            id: itemID,
            parentApplicationID: applicationID,
            timestamp: timestamp,
            title: "Hello",
            body: "There",
            appName: "Chat"
        )
    }

    private var sourceApp: NotificationSourceApp {
        NotificationSourceApp(bundleID: "com.example.chat", displayName: "Chat")
    }

    private var glance: AppGlance {
        AppGlance(
            applicationID: applicationID,
            slices: [AppGlanceSlice(subtitleTemplate: "In a moment")],
            updatedAt: timestamp
        )
    }

    private var report: WeatherReport {
        WeatherReport(
            id: itemID,
            locationName: "Tokyo",
            isCurrentLocation: true,
            currentTemperature: 21,
            currentType: .sun,
            todayHigh: 24,
            todayLow: 17,
            tomorrowType: .lightRain,
            tomorrowHigh: 22,
            tomorrowLow: 16,
            shortPhrase: "Clear",
            updated: timestamp
        )
    }

    private var day: WatchHealthDay {
        WatchHealthDay(
            weekday: 3,
            lastProcessed: timestamp,
            steps: 8_000,
            activeKilocalories: 300,
            restingKilocalories: 1_400,
            distanceMetres: 6_200,
            activeSeconds: 2_700,
            sleepSeconds: 25_200,
            deepSleepSeconds: 7_200
        )
    }

    /// The token is the transport's, so a record has to build the same frame for
    /// whichever one it is handed. Not 1: the emulator hard-coded that for seven
    /// of these writes, and a frame that only happens to be right for token 1
    /// would have passed.
    private let token: UInt16 = 0x1234

    private func expect(
        _ record: BlobDBRecord,
        _ expected: [PebbleProtocolFrame],
        accepting statuses: [BlobDBStatus]
    ) throws {
        let writes = record.writes
        #expect(writes.count == expected.count)
        for (write, frame) in zip(writes, expected) {
            #expect(write.acceptedStatuses == statuses)
            let built = try write.makeFrame(token)
            #expect(built.endpoint == BlobDBCodec.endpoint)
            #expect(built.payload == frame.payload)
        }
    }

    private func expect(
        _ key: BlobDBKey,
        _ expected: PebbleProtocolFrame,
        accepting statuses: [BlobDBStatus]
    ) throws {
        let writes = key.writes
        #expect(writes.count == 1)
        let write = try #require(writes.first)
        #expect(write.acceptedStatuses == statuses)
        #expect(try write.makeFrame(token).payload == expected.payload)
    }

    private let owned: [BlobDBStatus] = [.success, .dataStale]
    private let gone: [BlobDBStatus] = [.success, .keyDoesNotExist]

    @Test func anApplicationRecordIsAnInsertTheWatchMayCallStale() throws {
        try expect(
            .application(metadata),
            [BlobDBCodec.insertApplicationFrame(metadata: metadata, token: token)],
            accepting: owned
        )
    }

    /// A notification the watch already holds was not shown, which is the one
    /// thing sending one is for — so `.dataStale` is a refusal here and a
    /// success everywhere else.
    @Test func aNotificationAcceptsOnlySuccess() throws {
        try expect(
            .notification(notification),
            [try TimelineNotificationCodec.insertFrame(notification, token: token)],
            accepting: [.success]
        )
    }

    @Test func aPinAndAReminderCarryTheSameItemToDifferentDatabases() throws {
        try expect(
            .timelinePin(pin),
            [try TimelinePinCodec.insertFrame(pin, token: token)],
            accepting: [.success]
        )
        try expect(
            .timelineReminder(pin),
            [try TimelineReminderCodec.insertFrame(pin, token: token)],
            accepting: [.success]
        )
        #expect(TimelinePinCodec.databaseID != TimelineReminderCodec.databaseID)
    }

    @Test func aNotificationSourceAppIsWrittenByItsBundleID() throws {
        try expect(
            .notificationSourceApp(sourceApp),
            [NotificationAppsCodec.insertFrame(app: sourceApp, token: token)],
            accepting: owned
        )
    }

    @Test func aGlanceIsWrittenToTheGlanceDatabase() throws {
        try expect(
            .appGlance(glance),
            [AppGlanceCodec.insertFrame(glance, token: token)],
            accepting: owned
        )
    }

    @Test func aForecastAndTheOrderOfForecastsAreTwoRecords() throws {
        try expect(
            .weather(report),
            [WeatherCodec.insertFrame(report: report, token: token)],
            accepting: owned
        )
        try expect(
            .weatherOrder([itemID, applicationID]),
            [WeatherCodec.preferencesFrame(orderedIDs: [itemID, applicationID], token: token)],
            accepting: owned
        )
    }

    @Test func aWatchSettingCarriesItsOwnValue() throws {
        for setting in WatchSetting.allCases {
            // Every value the setting has, whether that is two or four of them.
            let values = setting.optionRawValues
            for rawValue in values {
                try expect(
                    .watchSetting(setting, rawValue: rawValue),
                    [WatchSettingsCodec.insertFrame(setting, rawValue: rawValue, token: token)],
                    accepting: owned
                )
            }
        }
    }

    @Test func activityAndHeartRateSettingsShareADatabaseAndNotAKey() throws {
        let activity = ActivitySettings()
        let heartRate = HeartRateSettings()
        try expect(
            .activitySettings(activity),
            [HealthSettingsCodec.insertFrame(activity, token: token)],
            accepting: owned
        )
        try expect(
            .heartRateSettings(heartRate),
            [HealthSettingsCodec.insertFrame(heartRate, token: token)],
            accepting: owned
        )
        #expect(HealthSettingsCodec.activityKey != HealthSettingsCodec.heartRateKey)
    }

    /// Blood oxygen is three prefs, not one packed record: the on/off bit, the
    /// interval, and the during-activity bit, each its own key and its own write.
    @Test func bloodOxygenIsThreeSeparateKeyWrites() throws {
        let settings = BloodOxygenSettings(
            isEnabled: true,
            interval: .everyThirtyMinutes,
            isEnabledDuringActivity: true
        )
        try expect(
            .bloodOxygenSettings(settings),
            [
                HealthSettingsCodec.bloodOxygenEnabledFrame(true, token: token),
                HealthSettingsCodec.spo2IntervalFrame(.everyThirtyMinutes, token: token),
                HealthSettingsCodec.bloodOxygenActivityFrame(true, token: token),
            ],
            accepting: owned
        )
        // The interval is one byte, as ActivitySpO2Settings is on the watch.
        let intervalPayload = HealthSettingsCodec
            .spo2IntervalFrame(.everyThirtyMinutes, token: token).payload
        #expect(intervalPayload.suffix(1) == [HeartRateInterval.everyThirtyMinutes.rawValue])
        // Four distinct keys: the three blood-oxygen ones and heart rate's.
        let keys = Set([
            HealthSettingsCodec.bloodOxygenKey,
            HealthSettingsCodec.spo2IntervalKey,
            HealthSettingsCodec.bloodOxygenActivityKey,
            HealthSettingsCodec.heartRateKey,
        ])
        #expect(keys.count == 4)
    }

    /// Two records under two keys, movement before sleep, which is the order the
    /// Bluetooth client sent them in.
    @Test func aHealthDayIsTwoWritesMovementThenSleep() throws {
        try expect(
            .healthDay(day),
            [
                HealthStatsCodec.movementFrame(for: day, token: token),
                HealthStatsCodec.sleepFrame(for: day, token: token),
            ],
            accepting: owned
        )
    }

    @Test func theReminderAppSwitchGoesIntoThePreferencesDatabase() throws {
        try expect(
            .reminderAppState(.enabled),
            [WeatherCodec.reminderAppFrame(state: .enabled, token: token)],
            accepting: owned
        )
    }

    @Test func everyDeleteAcceptsAKeyThatWasAlreadyGone() throws {
        try expect(
            .application(applicationID),
            BlobDBCodec.deleteApplicationFrame(applicationID: applicationID, token: token),
            accepting: gone
        )
        try expect(
            .timelinePin(itemID),
            TimelinePinCodec.deleteFrame(id: itemID, token: token),
            accepting: gone
        )
        try expect(
            .timelineReminder(itemID),
            TimelineReminderCodec.deleteFrame(id: itemID, token: token),
            accepting: gone
        )
        try expect(
            .notificationSourceApp(bundleID: sourceApp.bundleID),
            NotificationAppsCodec.deleteFrame(bundleID: sourceApp.bundleID, token: token),
            accepting: gone
        )
        try expect(
            .appGlance(applicationID: applicationID),
            AppGlanceCodec.deleteFrame(applicationID: applicationID, token: token),
            accepting: gone
        )
        try expect(
            .weather(itemID),
            WeatherCodec.deleteFrame(id: itemID, token: token),
            accepting: gone
        )
    }

    /// A clear takes no key, so there is no key that could be missing.
    @Test func clearingThePinsAcceptsOnlySuccess() throws {
        try expect(
            .allTimelinePins,
            TimelinePinCodec.clearFrame(token: token),
            accepting: [.success]
        )
    }
}
