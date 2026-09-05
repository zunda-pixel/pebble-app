public import Foundation

/// One frame to send, and what the watch is allowed to answer with.
///
/// The pair travels together because a status only means something against the
/// write it answers: `.dataStale` is a refusal for a notification that was
/// meant to buzz and a success for a record the phone owns outright.
public struct BlobDBWrite: Sendable {
    public var acceptedStatuses: [BlobDBStatus]
    public var makeFrame: @Sendable (UInt16) throws -> PebbleProtocolFrame

    public init(
        acceptedStatuses: [BlobDBStatus],
        makeFrame: @escaping @Sendable (UInt16) throws -> PebbleProtocolFrame
    ) {
        self.acceptedStatuses = acceptedStatuses
        self.makeFrame = makeFrame
    }
}

/// Something the phone writes into one of the watch's databases.
///
/// Which database, what bytes, and which reply counts as success are all facts
/// about the record, so they live here beside the codecs rather than in each
/// transport. Written out per transport they had already drifted: the emulator
/// sent seven of these without reading the reply at all, and refused an
/// application whose record the watch already held.
public enum BlobDBRecord: Equatable, Sendable {
    case application(PebbleAppMetadata)
    case notification(PebbleTimelineNotification)
    case timelinePin(TimelinePin)
    case timelineReminder(TimelinePin)
    case notificationSourceApp(NotificationSourceApp)
    case appGlance(AppGlance)
    case weather(WeatherReport)
    /// A forecast the watch holds but this list does not name is not shown.
    case weatherOrder([UUID])
    /// Only the settings the firmware lists as syncable are accepted.
    case watchSetting(WatchSetting, isOn: Bool)
    case activitySettings(ActivitySettings)
    case heartRateSettings(HeartRateSettings)
    case healthDay(WatchHealthDay)
    case reminderAppState(PebbleReminderAppState)

    /// The frames this record turns into, in the order they must be sent.
    public var writes: [BlobDBWrite] {
        switch self {
        case .application(let metadata):
            [Self.owned { BlobDBCodec.insertApplicationFrame(metadata: metadata, token: $0) }]

        case .notification(let notification):
            // Not `.dataStale`: there the watch recognised the notification and
            // did not show it, which is the one thing sending one is for.
            [BlobDBWrite(acceptedStatuses: [.success]) {
                try TimelineNotificationCodec.insertFrame(notification, token: $0)
            }]

        case .timelinePin(let pin):
            [BlobDBWrite(acceptedStatuses: [.success]) { try TimelinePinCodec.insertFrame(pin, token: $0) }]

        case .timelineReminder(let reminder):
            [BlobDBWrite(acceptedStatuses: [.success]) {
                try TimelineReminderCodec.insertFrame(reminder, token: $0)
            }]

        case .notificationSourceApp(let app):
            [Self.owned { NotificationAppsCodec.insertFrame(app: app, token: $0) }]

        case .appGlance(let glance):
            [Self.owned { AppGlanceCodec.insertFrame(glance, token: $0) }]

        case .weather(let report):
            [Self.owned { WeatherCodec.insertFrame(report: report, token: $0) }]

        case .weatherOrder(let orderedIDs):
            [Self.owned { WeatherCodec.preferencesFrame(orderedIDs: orderedIDs, token: $0) }]

        case .watchSetting(let setting, let isOn):
            [Self.owned { WatchSettingsCodec.insertFrame(setting, isOn: isOn, token: $0) }]

        case .activitySettings(let settings):
            [Self.owned { HealthSettingsCodec.insertFrame(settings, token: $0) }]

        case .heartRateSettings(let settings):
            [Self.owned { HealthSettingsCodec.insertFrame(settings, token: $0) }]

        case .healthDay(let day):
            // The firmware keeps a day's movement and its sleep as two records
            // under two keys, so one day is two writes.
            [
                Self.owned { HealthStatsCodec.movementFrame(for: day, token: $0) },
                Self.owned { HealthStatsCodec.sleepFrame(for: day, token: $0) },
            ]

        case .reminderAppState(let state):
            [Self.owned { WeatherCodec.reminderAppFrame(state: state, token: $0) }]
        }
    }

    /// A record the phone owns outright, where the watch already holding this
    /// exact one is as good as having taken it: `.dataStale` means it will
    /// never accept it again, and there is nothing left to do about that.
    private static func owned(
        _ makeFrame: @escaping @Sendable (UInt16) throws -> PebbleProtocolFrame
    ) -> BlobDBWrite {
        BlobDBWrite(acceptedStatuses: [.success, .dataStale], makeFrame: makeFrame)
    }
}

/// Something the phone takes back off the watch.
public enum BlobDBKey: Equatable, Sendable {
    case application(UUID)
    case timelinePin(UUID)
    case timelineReminder(UUID)
    case notificationSourceApp(bundleID: String)
    case appGlance(applicationID: UUID)
    case weather(UUID)
    /// Empties the watch's pin database, including pins this app never sent.
    /// BlobDB cannot be listed, so this is the only reach for a pin the app has
    /// no record of.
    case allTimelinePins

    public var writes: [BlobDBWrite] {
        switch self {
        case .application(let applicationID):
            [Self.gone { BlobDBCodec.deleteApplicationFrame(applicationID: applicationID, token: $0) }]
        case .timelinePin(let id):
            [Self.gone { TimelinePinCodec.deleteFrame(id: id, token: $0) }]
        case .timelineReminder(let id):
            [Self.gone { TimelineReminderCodec.deleteFrame(id: id, token: $0) }]
        case .notificationSourceApp(let bundleID):
            [Self.gone { NotificationAppsCodec.deleteFrame(bundleID: bundleID, token: $0) }]
        case .appGlance(let applicationID):
            [Self.gone { AppGlanceCodec.deleteFrame(applicationID: applicationID, token: $0) }]
        case .weather(let id):
            [Self.gone { WeatherCodec.deleteFrame(id: id, token: $0) }]
        case .allTimelinePins:
            // A clear takes no key, so there is no key that could be missing.
            [BlobDBWrite(acceptedStatuses: [.success]) { TimelinePinCodec.clearFrame(token: $0) }]
        }
    }

    /// A key the watch does not have is a key the watch does not have, which is
    /// what the caller asked for.
    private static func gone(
        _ makeFrame: @escaping @Sendable (UInt16) throws -> PebbleProtocolFrame
    ) -> BlobDBWrite {
        BlobDBWrite(acceptedStatuses: [.success, .keyDoesNotExist], makeFrame: makeFrame)
    }
}
