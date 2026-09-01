import API
import Foundation

/// Sample values for previews.
///
/// Held here rather than beside each `#Preview` so that a screen and the rows it
/// is made of are previewed against the same data, and so that a change to one
/// of these types is a compile error in one file instead of a dozen.
enum PreviewSamples {
    static let watch = PebbleDevice(
        id: "preview-watch",
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

    static let savedWatch = SavedPebbleWatch(
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

    static let discovered = DiscoveredPebble(
        id: "preview-discovered",
        name: "Pebble ABCD",
        model: .pebbleRound2,
        signalStrength: -62
    )

    static let pins: [PebbleTimelinePin] = {
        let day = Calendar.current.startOfDay(for: .now)
        return [
            PebbleTimelinePin(
                parentApplicationID: UUID(),
                timestamp: day.addingTimeInterval(9 * 3_600),
                title: "スタンドアップ",
                subtitle: "Room 3",
                body: nil
            ),
            PebbleTimelinePin(
                parentApplicationID: UUID(),
                timestamp: day.addingTimeInterval(13 * 3_600),
                title: "Lunch with Ann",
                subtitle: nil,
                body: nil
            ),
            PebbleTimelinePin(
                parentApplicationID: UUID(),
                timestamp: day.addingTimeInterval(26 * 3_600),
                title: "Dentist",
                subtitle: nil,
                body: nil,
                isAllDay: true
            ),
        ]
    }()

    static let reminders: [PebbleTimelinePin] = [
        PebbleTimelinePin(
            parentApplicationID: UUID(),
            timestamp: .now.addingTimeInterval(3_600),
            title: "Take the bins out",
            subtitle: nil,
            body: nil,
            kind: .reminder
        ),
        PebbleTimelinePin(
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

    static let healthSamples: [PebbleHealthSample] = (0..<14).reversed().map { day in
        PebbleHealthSample(
            date: Calendar.current.date(byAdding: .day, value: -day, to: .now) ?? .now,
            steps: 6_000 + day * 431 % 5_000,
            sleepMinutes: 360 + day * 17 % 120
        )
    }

    static let watchApplications: [PebbleApplication] = [
        PebbleApplication(
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
        PebbleApplication(
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

    static let watchfaces: [PebbleApplication] = [
        PebbleApplication(
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

    static let catalogApplication = PebbleCatalogApplication(
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

    static let logLines: [WatchLogLine] = [
        WatchLogLine(date: .now, level: 100, file: "pebble_app.c", line: 412, message: "app launched"),
        WatchLogLine(date: .now, level: 1, file: "bt_conn_mgr.c", line: 88, message: "link lost, reason=0x08"),
        WatchLogLine(date: .now, level: 200, file: "health_service.c", line: 1_203, message: "steps=8241"),
    ]

    static let transferProgress = PutBytesTransferProgress(bytesSent: 240_000, totalBytes: 512_000)
}
