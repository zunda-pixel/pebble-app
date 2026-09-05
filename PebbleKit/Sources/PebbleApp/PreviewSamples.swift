import PebbleProtocol
import PebbleTransport
import Foundation

/// Sample values for previews.
///
/// Held here rather than beside each `#Preview` so that a screen and the rows it
/// is made of are previewed against the same data, and so that a change to one
/// of these types is a compile error in one file instead of a dozen.
enum PreviewSamples {
    static let watch = ConnectedWatch(
        id: WatchID("preview-watch"),
        name: "Pebble 5209",
        model: .pebbleTime2,
        firmwareVersion: "v4.36.2",
        batteryLevel: 72,
        serialNumber: "Q402P000000A",
        board: .obelixPVT,
        languageLocale: "ja_JP",
        languageVersion: 1,
        capabilities: .max
    )

    static let savedWatch = SavedWatch(
        id: watch.id,
        name: watch.name,
        model: watch.model,
        firmwareVersion: watch.firmwareVersion,
        serialNumber: watch.serialNumber,
        lastBatteryLevel: watch.batteryLevel,
        lastConnectedAt: .now,
        automaticallyConnects: true,
        board: watch.board
    )

    static let discovered = DiscoveredWatch(
        id: WatchID("preview-discovered"),
        name: "Pebble ABCD",
        model: .pebbleRound2,
        signalStrength: -62
    )

    static let connectedSummary = WatchSummary(
        id: watch.id,
        name: watch.name,
        model: watch.model,
        serialNumber: watch.serialNumber,
        batteryLevel: watch.batteryLevel,
        firmwareVersion: watch.firmwareVersion,
        languageLocale: watch.languageLocale,
        phase: .connected,
        isSaved: true,
        automaticallyConnects: true,
        lastConnectedAt: .now
    )

    static let recoverySummary = WatchSummary(
        id: WatchID("recovery-watch"),
        name: "Pebble 33EE",
        model: .pebble2Duo,
        batteryLevel: 63,
        firmwareVersion: "v4.9.142",
        isRunningRecoveryFirmware: true,
        phase: .connected,
        isSaved: true,
        automaticallyConnects: true,
        lastConnectedAt: .now
    )

    static let savedSummary = WatchSummary(
        id: WatchID("saved-watch"),
        name: "Pebble 2 Duo",
        model: .pebble2Duo,
        serialNumber: "Q403P000001B",
        batteryLevel: 41,
        firmwareVersion: "v4.36.1",
        isSaved: true,
        lastConnectedAt: .now.addingTimeInterval(-86_400)
    )

    static let pins: [TimelinePin] = {
        let day = Calendar.current.startOfDay(for: .now)
        return [
            TimelinePin(
                parentApplicationID: UUID(),
                timestamp: day.addingTimeInterval(9 * 3_600),
                title: "スタンドアップ",
                subtitle: "Room 3",
                body: nil
            ),
            TimelinePin(
                parentApplicationID: UUID(),
                timestamp: day.addingTimeInterval(13 * 3_600),
                title: "Lunch with Ann",
                subtitle: nil,
                body: nil
            ),
            TimelinePin(
                parentApplicationID: UUID(),
                timestamp: day.addingTimeInterval(26 * 3_600),
                title: "Dentist",
                subtitle: nil,
                body: nil,
                isAllDay: true
            ),
        ]
    }()

    static let reminders: [TimelinePin] = [
        TimelinePin(
            parentApplicationID: UUID(),
            timestamp: .now.addingTimeInterval(3_600),
            title: "Take the bins out",
            subtitle: nil,
            body: nil,
            kind: .reminder
        ),
        TimelinePin(
            parentApplicationID: UUID(),
            timestamp: .now.addingTimeInterval(-7_200),
            title: "薬を飲む",
            subtitle: nil,
            body: nil,
            kind: .reminder
        ),
    ]

    static let notificationApps: [NotificationSourceApp] = [
        NotificationSourceApp(bundleID: "com.apple.MobileSMS", displayName: "Messages"),
        NotificationSourceApp(
            bundleID: "com.tinyspeck.chatlyio",
            displayName: "Slack",
            muteState: .always,
            icon: .generic,
            backgroundColor: PebbleColor(red: 2, green: 0, blue: 3),
            foregroundColor: PebbleColor(red: 3, green: 3, blue: 3)
        ),
        NotificationSourceApp(bundleID: "com.apple.mobilecal", displayName: "カレンダー", muteState: .weekends),
    ]

    static let sentNotifications: [SentNotification] = [
        SentNotification(
            appName: "Pebble",
            title: "Pebble Test",
            body: "Notifications are reaching your watch.",
            sentAt: Date(timeIntervalSince1970: 1_788_349_380),
            watchNames: ["My Pebble"]
        ),
        SentNotification(
            appName: "Weather",
            title: "Rain in Kyoto",
            body: "It starts at about four.",
            sentAt: Date(timeIntervalSince1970: 1_788_345_780),
            watchNames: ["My Pebble", "Pebble Time 2"]
        ),
    ]

    static let healthSamples: [WatchHealthSample] = (0..<14).reversed().map { day in
        let date = Calendar.current.date(byAdding: .day, value: -day, to: .now) ?? .now
        let asleep = TimeInterval(360 + day * 17 % 120) * 60
        let bedtime = Calendar.current.startOfDay(for: date).addingTimeInterval(-3600)
        return WatchHealthSample(
            date: date,
            steps: 6_000 + day * 431 % 5_000,
            sleepMinutes: Int(asleep / 60),
            deepSleepMinutes: Int(asleep / 60 / 4),
            sleepSessions: [SleepSession(
                start: bedtime,
                end: bedtime.addingTimeInterval(asleep),
                asleep: asleep,
                deep: asleep / 4
            )],
            activeKilocalories: 320 + day * 37 % 200,
            restingKilocalories: 1_500,
            distanceMetres: 4_800 + day * 311 % 3_000,
            activeMinutes: 28 + day * 7 % 40
        )
    }

    static let watchApplications: [WatchApplication] = [
        WatchApplication(
            id: UUID(),
            shortName: "Timeline",
            longName: "Timeline Weather",
            companyName: "Core Devices",
            versionCode: 3,
            versionLabel: "1.3",
            capabilities: ["configurable"],
            targetPlatforms: ["emery", "obelix"],
            kind: .watchapp,
            hasCompanionJavaScript: true
        ),
        WatchApplication(
            id: UUID(),
            shortName: "Steps",
            longName: "",
            companyName: "zunda",
            versionCode: 1,
            versionLabel: "0.4",
            capabilities: [],
            targetPlatforms: ["emery"],
            kind: .watchapp
        ),
    ]

    static let watchfaces: [WatchApplication] = [
        WatchApplication(
            id: UUID(),
            shortName: "Tick",
            longName: "Tick Tock",
            companyName: "Pebble",
            versionCode: 2,
            versionLabel: "2.0",
            capabilities: [],
            targetPlatforms: ["emery", "obelix", "gabbro"],
            kind: .watchface
        ),
    ]

    static let catalogApplication = CatalogApplication(
        id: UUID(),
        storeID: "5262d3e2b3d4d2c9a1000000",
        name: "Simply Light",
        developer: "Rebble",
        version: "2.1",
        downloadURL: URL(string: "https://example.invalid/simply-light.pbw")!,
        supportedPlatforms: ["emery", "obelix"],
        kind: .watchface,
        category: "Faces",
        summary: "A watchface with nothing on it but the time."
    )

    static let weatherPlaces: [WeatherPlace] = [
        WeatherPlace(id: UUID(), name: "現在地", latitude: 35.68, longitude: 139.76, followsPhone: true),
        WeatherPlace(id: UUID(), name: "Kyoto", latitude: 35.01, longitude: 135.76, followsPhone: false),
    ]

    static let weatherReports: [WeatherReport] = weatherPlaces.enumerated().map { index, place in
        WeatherReport(
            id: place.id,
            locationName: place.name,
            isCurrentLocation: place.followsPhone,
            currentTemperature: Int16(21 + index * 3),
            currentType: index == 0 ? .sun : .lightRain,
            todayHigh: Int16(26 + index),
            todayLow: Int16(17 + index),
            tomorrowType: .cloudyDay,
            tomorrowHigh: Int16(24 + index),
            tomorrowLow: Int16(16 + index),
            shortPhrase: index == 0 ? "晴れ" : "Light rain",
            updated: .now
        )
    }

    static let weatherCredit = WeatherCredit(
        serviceName: "Weather",
        lightMarkURL: URL(string: "https://example.invalid/light.png")!,
        darkMarkURL: URL(string: "https://example.invalid/dark.png")!,
        legalPageURL: URL(string: "https://example.invalid/legal")!
    )

    static let firmwareRelease = PebbleOSFirmwareRelease(
        versionTag: "v4.37.0",
        board: .obelixPVT,
        downloadURL: URL(string: "https://example.invalid/normal_obelix_pvt_v4.37.0.pbz")!,
        sizeInBytes: 1_048_576,
        releaseNotesURL: nil
    )

    static let downloadedFirmware = DownloadedFirmware(
        versionTag: firmwareRelease.versionTag,
        board: .obelixPVT,
        url: URL(fileURLWithPath: "/tmp/normal_obelix_pvt_v4.37.0.pbz")
    )

    static func firmwareJournal(phase: FirmwareUpdatePhase) -> FirmwareUpdateJournal {
        FirmwareUpdateJournal(
            watchID: watch.id,
            hardwareRevision: "obelix_pvt",
            previousVersion: watch.firmwareVersion,
            targetVersion: firmwareRelease.versionTag,
            packageSHA256: String(repeating: "a", count: 64),
            phase: phase
        )
    }

    static let logLines: [WatchLogLine] = [
        WatchLogLine(date: .now, level: 100, file: "pebble_app.c", line: 412, message: "app launched"),
        WatchLogLine(date: .now, level: 1, file: "bt_conn_mgr.c", line: 88, message: "link lost, reason=0x08"),
        WatchLogLine(date: .now, level: 200, file: "health_service.c", line: 1_203, message: "steps=8241"),
    ]

    static let transferProgress = PutBytesTransferProgress(bytesSent: 240_000, totalBytes: 512_000)

    /// A model on a mock transport, for the navigation shells whose whole job is
    /// the chrome around a screen. What each screen shows previews from its own
    /// content view instead: a screen that loads from disk in `.task` would
    /// overwrite anything set here.
    @MainActor
    static func appModel() -> AppModel {
        let model = AppModel(client: MockWatchClient())
        model.watches.saved = [savedWatch]
        model.applications.apps = watchApplications
        model.applications.watchfaces = watchfaces
        model.weather.places = weatherPlaces
        model.notifications.sourceApps = notificationApps
        return model
    }
}
