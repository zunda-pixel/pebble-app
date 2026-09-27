import Foundation
import PebbleProtocol

/// A launcher line as a watch app's JavaScript writes it: the slices
/// `Pebble.appGlanceReload` takes, in the SDK's own JSON. An empty list is the
/// documented way to take the glance down, and parses to no slices.
enum CompanionAppGlance {
    enum ParseError: Error, Equatable {
        case unreadable
        case notAList
        /// More slices than the watch keeps
        /// (`APP_GLANCE_DB_MAX_SLICES_PER_GLANCE`): refused rather than
        /// silently trimmed, so the script's author finds out.
        case tooManySlices
        case sliceWithoutALayout
    }

    static func slices(from json: String) throws -> [AppGlanceSlice] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            throw ParseError.unreadable
        }
        guard let list = object as? [Any] else { throw ParseError.notAList }
        guard list.count <= AppGlanceCodec.maximumSlices else { throw ParseError.tooManySlices }
        return try list.map { entry in
            guard let slice = entry as? [String: Any],
                  let layout = slice["layout"] as? [String: Any] else {
                throw ParseError.sliceWithoutALayout
            }
            return AppGlanceSlice(
                subtitleTemplate: layout["subtitleTemplateString"] as? String ?? "",
                // An icon this app cannot name stays nil, which leaves the
                // watch the app's own icon — the same answer the editor gives.
                icon: (layout["icon"] as? String).flatMap(TimelineIcon.init(systemImageURI:)),
                expires: (slice["expirationTime"] as? String).flatMap(Date.init(webTimestamp:))
            )
        }
    }
}

extension TimelineIcon {
    /// The SDK's `system://images/<NAME>` spelling for an icon, read into the
    /// firmware's resource id. The table is the official app's
    /// (`TimelineIcon.kt`), kept to the names whose ids exist on the boards
    /// this app supports — an unknown name is nil, not a guess.
    init?(systemImageURI: String) {
        let prefix = "system://images/"
        guard systemImageURI.hasPrefix(prefix) else { return nil }
        let name = String(systemImageURI.dropFirst(prefix.count))
        guard let id = Self.systemImageIdentifiers[name],
              let icon = TimelineIcon(rawValue: id) else { return nil }
        self = icon
    }

    private static let systemImageIdentifiers: [String: UInt32] = [
        "ALARM_CLOCK": 13,
        "AUDIO_CASSETTE": 12,
        "DURING_PHONE_CALL": 49,
        "GENERIC_CONFIRMATION": 55,
        "GENERIC_EMAIL": 19,
        "GENERIC_QUESTION": 63,
        "GENERIC_SMS": 45,
        "GENERIC_WARNING": 28,
        "GLUCOSE_MONITOR": 29,
        "MUSIC_EVENT": 35,
        "NEWS_EVENT": 36,
        "NOTIFICATION_AMAZON": 111,
        "NOTIFICATION_BLACKBERRY_MESSENGER": 58,
        "NOTIFICATION_BLUESKY": 122,
        "NOTIFICATION_FACEBOOK": 11,
        "NOTIFICATION_FACEBOOK_MESSENGER": 10,
        "NOTIFICATION_FACETIME": 110,
        "NOTIFICATION_FLAG": 4,
        "NOTIFICATION_GENERIC": 1,
        "NOTIFICATION_GMAIL": 9,
        "NOTIFICATION_GOOGLE_HANGOUTS": 8,
        "NOTIFICATION_GOOGLE_INBOX": 61,
        "NOTIFICATION_GOOGLE_MAPS": 112,
        "NOTIFICATION_GOOGLE_MESSENGER": 76,
        "NOTIFICATION_GOOGLE_PHOTOS": 113,
        "NOTIFICATION_HIPCHAT": 77,
        "NOTIFICATION_INSTAGRAM": 59,
        "NOTIFICATION_IOS_PHOTOS": 114,
        "NOTIFICATION_KAKAOTALK": 79,
        "NOTIFICATION_KIK": 80,
        "NOTIFICATION_LIGHTHOUSE": 81,
        "NOTIFICATION_LINE": 67,
        "NOTIFICATION_LINKEDIN": 115,
        "NOTIFICATION_MAILBOX": 60,
        "NOTIFICATION_OUTLOOK": 64,
        "NOTIFICATION_REMINDER": 3,
        "NOTIFICATION_SIGNAL": 135,
        "NOTIFICATION_SKYPE": 68,
        "NOTIFICATION_SLACK": 116,
        "NOTIFICATION_SNAPCHAT": 69,
        "NOTIFICATION_TELEGRAM": 7,
        "NOTIFICATION_TWITCH": 136,
        "NOTIFICATION_TWITTER": 6,
        "NOTIFICATION_VIBER": 70,
        "NOTIFICATION_WECHAT": 71,
        "NOTIFICATION_WHATSAPP": 5,
        "NOTIFICATION_YAHOO_MAIL": 72,
        "PAY_BILL": 38,
        "RESULT_DELETED": 43,
        "RESULT_DISMISSED": 51,
        "RESULT_FAILED": 62,
        "RESULT_MUTE": 46,
        "RESULT_SENT": 47,
        "SCHEDULED_EVENT": 40,
        "TIMELINE_CALENDAR": 21,
        "TIMELINE_MISSED_CALL": 2,
        "TIMELINE_SPORTS": 17,
        "TIMELINE_WEATHER": 14,
    ]
}
