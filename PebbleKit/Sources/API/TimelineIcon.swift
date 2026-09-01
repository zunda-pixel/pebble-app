/// The numbers are the firmware's `TimelineResourceId`s, which are generated
/// per board; these are the ones that come out the same on asterix, obelix and
/// gabbro.
public enum PebbleTimelineIcon: UInt32, CaseIterable, Codable, Sendable {
    case generic = 1
    case missedCall = 2
    case reminder = 3
    case flag = 4
    case whatsApp = 5
    case twitter = 6
    case telegram = 7
    case googleHangouts = 8
    case gmail = 9
    case facebookMessenger = 10
    case facebook = 11
    case audioCassette = 12
    case alarmClock = 13
    case weather = 14
    case sports = 17
    case email = 19
    case calendar = 21
    case warning = 28
    case glucoseMonitor = 29
    case musicEvent = 35
    case newsEvent = 36
    case payBill = 38
    case scheduledEvent = 40
    case deleted = 43
    case sms = 45
    case muted = 46
    case sent = 47
    case duringPhoneCall = 49
    case dismissed = 51
    case confirmation = 55
    case blackBerryMessenger = 58
    case instagram = 59
    case mailbox = 60
    case googleInbox = 61
    case failed = 62
    case question = 63
    case outlook = 64
    case line = 67
    case skype = 68
    case snapchat = 69
    case viber = 70
    case weChat = 71
    case yahooMail = 72
    case googleMessenger = 76
    case hipChat = 77
    case kakaoTalk = 79
    case kik = 80
    case lighthouse = 81
    case faceTime = 110
    case amazon = 111
    case googleMaps = 112
    case googlePhotos = 113
    case iOSPhotos = 114
    case linkedIn = 115
    case slack = 116
    case blueSky = 122
    case signal = 135
    case twitch = 136
    case airmail = 137
    case reddit = 138
    case swarm = 139
    case tapo = 140

    /// The high bit marks a resource of the system's rather than one of an app's.
    public var resourceID: UInt32 { 0x8000_0000 | rawValue }

    /// The watch already knows the apps whose own logo it has, so what is left to
    /// choose is the kind of thing a notification is.
    public static let choosable: [PebbleTimelineIcon] = [
        .generic, .sms, .email, .calendar, .reminder, .alarmClock, .duringPhoneCall,
        .missedCall, .musicEvent, .newsEvent, .payBill, .scheduledEvent, .warning,
        .question, .flag,
    ]

    /// What the firmware would pick for an iOS app by itself
    /// (`ancs_known_apps.h`).
    public static func suggested(forBundleID bundleID: String) -> PebbleTimelineIcon? {
        knownApplications[bundleID]
    }

    static let knownApplications: [String: PebbleTimelineIcon] = [
        "com.apple.mobilecal": .calendar,
        "com.apple.facetime": .faceTime,
        "com.apple.mobilemail": .email,
        "com.apple.mobilephone": .duringPhoneCall,
        "com.apple.reminders": .reminder,
        "com.apple.MobileSMS": .sms,
        "com.apple.mobileslideshow": .iOSPhotos,
        "com.atebits.Tweetie2": .twitter,
        "com.burbn.instagram": .instagram,
        "com.facebook.Facebook": .facebook,
        "com.facebook.Messenger": .facebookMessenger,
        "com.google.calendar": .calendar,
        "com.google.Gmail": .gmail,
        "com.google.hangouts": .googleHangouts,
        "com.google.inbox": .googleInbox,
        "com.google.Maps": .googleMaps,
        "com.google.photos": .googlePhotos,
        "com.google.GoogleMobile": .generic,
        "com.microsoft.Office.Outlook": .outlook,
        "com.orchestra.v2": .mailbox,
        "com.skype.skype": .skype,
        "com.tapbots.Tweetbot3": .twitter,
        "com.toyopagroup.picaboo": .snapchat,
        "com.yahoo.Aerogram": .yahooMail,
        "jp.naver.line": .line,
        "net.whatsapp.WhatsApp": .whatsApp,
        "ph.telegra.Telegraph": .telegram,
        "com.blackberry.bbm1": .blackBerryMessenger,
        "com.hipchat.ios": .hipChat,
        "com.iwilab.KakaoTalk": .kakaoTalk,
        "com.kik.chat": .kik,
        "com.tencent.xin": .weChat,
        "com.viber": .viber,
        "com.amazon.Amazon": .amazon,
        "com.linkedin.LinkedIn": .linkedIn,
        "com.tinyspeck.chatlyio": .slack,
        "xyz.blueskyweb.app": .blueSky,
        "org.whispersystems.signal": .signal,
        "tv.twitch": .twitch,
        "com.airmailapp.iphone": .airmail,
        "com.reddit.Reddit": .reddit,
        "com.foursquare.robin": .swarm,
        "com.tplink.tapo": .tapo,
        "com.revolut.revolut": .payBill,
        "com.transferwise.Transferwise": .payBill,
        "de.no26.Number26": .payBill,
        "com.bunq.ios": .payBill,
    ]
}
