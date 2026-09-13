public import Foundation
import MemberwiseInit

public enum NotificationAppMuteState: UInt8, Codable, Equatable, Sendable, CaseIterable {
    case never = 0
    case always = 127
    case weekdays = 62
    case weekends = 65

    public init(wireValue: UInt8) {
        self = NotificationAppMuteState(rawValue: wireValue) ?? .never
    }
}

/// How the watch buzzes for one app's notifications.
///
/// A pattern is a run of durations in milliseconds that alternate, starting
/// with the motor on: 200 on, 75 off, 200 on. The watch plays them exactly as
/// given (`vibes_enqueue_custom_pattern` in `applib/ui/vibes.c`), so these are
/// the same numbers the official app ships — a reader who knows a Pebble knows
/// these buzzes.
public enum NotificationVibePattern: String, Codable, Equatable, Sendable, CaseIterable {
    case silent
    case standard
    case pulses
    case double
    case triple
    case bloom
    case pips
    case ole
    case sos
    case ohhhOh
    case five
    case two

    public var durations: [UInt32] {
        switch self {
        // Not "no pattern": an empty run would leave the watch to its own
        // setting. One buzz of no length is how a phone says silence.
        case .silent: [0]
        case .standard: [500]
        case .pulses: [50, 50, 50, 50, 50, 50, 50]
        case .double: [200, 75, 200]
        case .triple: [200, 75, 200, 75, 200]
        case .bloom: [35, 61, 47, 53, 50, 40, 81, 171, 189, 236, 47, 70, 38, 44, 39, 62, 79, 171, 181]
        case .pips: [40, 960, 40, 960, 40, 960, 40, 960, 40, 960, 500]
        case .ole: [61, 194, 272, 153, 47, 77, 47, 78, 46, 89, 54, 78, 47, 70, 388]
        case .sos: [100, 75, 100, 75, 100, 220, 300, 75, 300, 75, 300, 150, 100, 75, 100, 75, 100]
        case .ohhhOh: [459, 522, 144, 171, 173, 162, 72, 135, 555, 386, 514]
        case .five: [68, 178, 80, 237, 54, 95, 122, 221, 154, 221, 139, 218, 81, 161, 137, 189, 55, 95, 130, 211, 188, 178, 222]
        case .two: [135, 269, 847, 394, 40, 159, 48, 170, 31, 144, 64, 136, 64, 162, 36, 163, 122]
        }
    }
}

/// Which part of a notification a rule reads.
public enum NotificationRuleField: UInt8, Codable, Equatable, Sendable, CaseIterable {
    /// The title and the body. The watch shows the subtitle on the title line,
    /// so a title rule reads that too (`ancs_filtering.c`).
    case anywhere = 0
    case title = 1
    case body = 2
}

/// A notification the reader does not want shown, named by something in it.
///
/// The watch looks for the pattern inside the field and drops the notification
/// when it finds it. It compares plainly — the firmware's own comparison, which
/// folds only ASCII letters when the rule is not case-sensitive. There is a
/// regular-expression rule type on the wire and the firmware answers `false` to
/// every one of them, so this app does not offer it.
@MemberwiseInit(.public)
public struct NotificationFilterRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var pattern: String
    public var field: NotificationRuleField = .anywhere
    public var isCaseSensitive: Bool = false

    // The file on disk keeps the name the field was first written under.
    private enum CodingKeys: String, CodingKey {
        case id, pattern, field
        case isCaseSensitive = "caseSensitive"
    }
}

/// The watch inserts a record for every app it sees sending notifications; the
/// phone writes back the parts of it that are the reader's to choose.
@MemberwiseInit(.public)
public struct NotificationSourceApp: Codable, Equatable, Sendable, Identifiable {
    public var bundleID: String
    public var displayName: String
    public var muteState: NotificationAppMuteState = .never
    public var muteExpiration: Date? = nil
    public var stateUpdated: Date = .now
    /// Nil leaves the choice of icon to the watch.
    public var icon: TimelineIcon? = nil
    public var backgroundColor: PebbleColor? = nil
    public var foregroundColor: PebbleColor? = nil
    /// Nil leaves the watch its own vibration setting.
    public var vibePattern: NotificationVibePattern? = nil
    /// Notifications from this app the watch is to drop rather than show.
    public var filterRules: [NotificationFilterRule] = []

    public var id: String { bundleID }

    /// The record as this watch can take it.
    ///
    /// An attribute a watch never said it supports is not one to send. The
    /// firmware writes an attribute it does not know into a stack array without
    /// checking the bounds (#13), so the cost of guessing is not a setting that
    /// fails to apply.
    ///
    /// A watch that reports no capabilities at all has not been asked yet;
    /// nothing extra goes to it either.
    public func asUnderstoodBy(_ device: ConnectedWatch) -> NotificationSourceApp {
        var record = self
        if !device.supportsCustomVibePatterns { record.vibePattern = nil }
        if !device.supportsNotificationFiltering { record.filterRules = [] }
        return record
    }
}

public enum NotificationAppsCodec {
    public static var databaseID: UInt8 { 6 }

    static let appNameAttribute: UInt8 = 30
    static let lastUpdatedAttribute: UInt8 = 14
    static let muteDayOfWeekAttribute: UInt8 = 40
    static let muteExpirationAttribute: UInt8 = 50
    static let iconAttribute: UInt8 = 48
    static let foregroundColorAttribute: UInt8 = 27
    static let backgroundColorAttribute: UInt8 = 28
    static let vibrationPatternAttribute: UInt8 = 49
    static let filteringRulesAttribute: UInt8 = 51
    static let maximumNameLength = 40
    /// What the firmware keeps of a string list; the rest it throws away
    /// (`MAX_LENGTH_CANNED_RESPONSES` in `attribute.c`). A rule cut in half
    /// would match something nobody asked for, so whole rules are dropped
    /// instead.
    static let maximumRulesLength = 512

    public static func key(for app: NotificationSourceApp) -> [UInt8] {
        Array(app.bundleID.utf8)
    }

    public static func value(for app: NotificationSourceApp) -> [UInt8] {
        var attributes: [[UInt8]] = [
            attribute(id: appNameAttribute, content: trimmedName(app.displayName)),
            attribute(id: muteDayOfWeekAttribute, content: [app.muteState.rawValue]),
            attribute(
                id: lastUpdatedAttribute,
                content: UInt32(clamping: Int(app.stateUpdated.timeIntervalSince1970)).littleEndianBytes
            ),
        ]
        let expiration = app.muteExpiration.map { UInt32(clamping: Int($0.timeIntervalSince1970)) } ?? 0
        attributes.append(attribute(id: muteExpirationAttribute, content: expiration.littleEndianBytes))
        if let icon = app.icon {
            attributes.append(attribute(id: iconAttribute, content: icon.resourceID.littleEndianBytes))
        }
        if let background = app.backgroundColor {
            attributes.append(attribute(id: backgroundColorAttribute, content: [background.argb]))
        }
        if let foreground = app.foregroundColor {
            attributes.append(attribute(id: foregroundColorAttribute, content: [foreground.argb]))
        }
        if let pattern = app.vibePattern {
            attributes.append(attribute(id: vibrationPatternAttribute, content: uint32List(pattern.durations)))
        }
        let rules = filteringRules(app.filterRules)
        if !rules.isEmpty {
            attributes.append(attribute(id: filteringRulesAttribute, content: rules))
        }

        var value: [UInt8] = UInt32(0).littleEndianBytes
        value.append(UInt8(attributes.count))
        // No actions: the watch's own reply action would need the phone to send the
        // message, which iOS does not allow.
        value.append(0)
        value.append(contentsOf: attributes.flatMap { $0 })
        return value
    }

    public static func insertFrame(app: NotificationSourceApp, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: key(for: app),
            value: value(for: app),
            token: token
        )
    }

    public static func deleteFrame(bundleID: String, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.deleteFrame(databaseID: databaseID, key: Array(bundleID.utf8), token: token)
    }

    public static func decodeRecord(
        key: [UInt8],
        value: [UInt8],
        timestamp: UInt32
    ) throws -> NotificationSourceApp {
        guard value.count >= 6 else {
            throw NotificationAppsCodecError.invalidRecord
        }
        let bundleID = String(decoding: key, as: UTF8.self)
        let attributeCount = Int(value[4])

        var displayName = bundleID
        var muteState = NotificationAppMuteState.never
        var muteExpiration: Date?
        var offset = 6
        for _ in 0..<attributeCount {
            guard value.count >= offset + 3 else {
                throw NotificationAppsCodecError.invalidRecord
            }
            let attributeID = value[offset]
            let length = Int(value[offset + 1]) | Int(value[offset + 2]) << 8
            offset += 3
            guard value.count >= offset + length else {
                throw NotificationAppsCodecError.invalidRecord
            }
            let content = Array(value[offset..<offset + length])
            offset += length

            switch attributeID {
            case appNameAttribute:
                displayName = String(decoding: content, as: UTF8.self)
            case muteDayOfWeekAttribute where !content.isEmpty:
                muteState = NotificationAppMuteState(wireValue: content[0])
            case muteExpirationAttribute where content.count >= 4:
                let epoch = UInt32(content[0])
                    | UInt32(content[1]) << 8
                    | UInt32(content[2]) << 16
                    | UInt32(content[3]) << 24
                muteExpiration = epoch == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(epoch))
            default:
                continue
            }
        }
        return NotificationSourceApp(
            bundleID: bundleID,
            displayName: displayName,
            muteState: muteState,
            muteExpiration: muteExpiration,
            stateUpdated: Date(timeIntervalSince1970: TimeInterval(timestamp))
        )
    }

    private static func attribute(id: UInt8, content: [UInt8]) -> [UInt8] {
        [id, UInt8(content.count & 0xFF), UInt8(content.count >> 8)] + content
    }

    /// The rules as the watch reads them: a count, and then each rule as three
    /// bytes and a pattern that ends at a zero.
    ///
    /// A pattern of no length matches everything the app sends, and one with a
    /// zero in it ends where the reader did not mean it to, so neither is sent.
    /// Rules past what the firmware keeps are dropped whole: half a pattern
    /// would silence something nobody named.
    static func filteringRules(_ rules: [NotificationFilterRule]) -> [UInt8] {
        var bodies: [[UInt8]] = []
        var length = 1
        for rule in rules {
            let pattern = Array(rule.pattern.utf8)
            guard !pattern.isEmpty, !pattern.contains(0) else { continue }
            let body = [0x00, rule.field.rawValue, rule.isCaseSensitive ? 1 : 0] + pattern + [0x00]
            guard length + body.count <= maximumRulesLength, bodies.count < 255 else { break }
            length += body.count
            bodies.append(body)
        }
        guard !bodies.isEmpty else { return [] }
        return [UInt8(bodies.count)] + bodies.flatMap { $0 }
    }

    /// The firmware's `Uint32List`: a count and then the values.
    ///
    /// The count is declared `uint16_t` in front of a `uint32_t` array, so the
    /// compiler puts two bytes of padding after it and the values start at four
    /// (`Uint32ListSize` in `attribute.h`). The padding is on the wire whether
    /// anything is written into it or not.
    private static func uint32List(_ values: [UInt32]) -> [UInt8] {
        var content = UInt16(clamping: values.count).littleEndianBytes + [0, 0]
        for value in values {
            content.append(contentsOf: value.littleEndianBytes)
        }
        return content
    }

    private static func trimmedName(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for character in name {
            let characterBytes = Array(String(character).utf8)
            guard bytes.count + characterBytes.count <= maximumNameLength else { break }
            bytes.append(contentsOf: characterBytes)
        }
        return bytes
    }
}

public enum NotificationAppsCodecError: Error, Equatable, Sendable {
    case invalidRecord
}

public enum BlobDB2Message: Equatable, Sendable {
    case write(BlobDB2Write)
    case writeBack(BlobDB2Write)
    case syncDone(tokenBytes: [UInt8])
}

@MemberwiseInit(.public)
public struct BlobDB2Write: Equatable, Sendable {
    public var tokenBytes: [UInt8]
    public var databaseID: UInt8
    public var timestamp: UInt32
    public var key: [UInt8]
    public var value: [UInt8]
}

/// The watch pushes its own records on this endpoint and expects an
/// acknowledgement for each.
public enum BlobDB2Codec {
    public static var endpoint: UInt16 { 0xB2DB }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> BlobDB2Message {
        guard frame.endpoint == endpoint else {
            throw BlobDB2CodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 3 else {
            throw BlobDB2CodecError.invalidPayload
        }
        let tokenBytes = Array(frame.payload[1...2])
        switch frame.payload[0] {
        case 0x08:
            return .write(try decodeWrite(frame.payload, tokenBytes: tokenBytes))
        case 0x09:
            return .writeBack(try decodeWrite(frame.payload, tokenBytes: tokenBytes))
        case 0x0A:
            return .syncDone(tokenBytes: tokenBytes)
        default:
            throw BlobDB2CodecError.unsupportedCommand
        }
    }

    public static func responseFrame(
        to message: BlobDB2Message,
        succeeded: Bool
    ) -> PebbleProtocolFrame {
        let command: UInt8
        let tokenBytes: [UInt8]
        switch message {
        case .write(let write):
            command = 0x88
            tokenBytes = write.tokenBytes
        case .writeBack(let write):
            command = 0x89
            tokenBytes = write.tokenBytes
        case .syncDone(let bytes):
            command = 0x8A
            tokenBytes = bytes
        }
        let status: UInt8 = succeeded ? 0x01 : 0x05
        return PebbleProtocolFrame(endpoint: endpoint, payload: [command] + tokenBytes + [status])
    }

    private static func decodeWrite(_ payload: [UInt8], tokenBytes: [UInt8]) throws -> BlobDB2Write {
        guard payload.count >= 9 else {
            throw BlobDB2CodecError.invalidPayload
        }
        let databaseID = payload[3]
        let timestamp = UInt32(payload[4])
            | UInt32(payload[5]) << 8
            | UInt32(payload[6]) << 16
            | UInt32(payload[7]) << 24
        let keySize = Int(payload[8])
        var offset = 9
        guard payload.count >= offset + keySize + 2 else {
            throw BlobDB2CodecError.invalidPayload
        }
        let key = Array(payload[offset..<offset + keySize])
        offset += keySize
        let valueSize = Int(payload[offset]) | Int(payload[offset + 1]) << 8
        offset += 2
        guard payload.count >= offset + valueSize else {
            throw BlobDB2CodecError.invalidPayload
        }
        let value = Array(payload[offset..<offset + valueSize])
        return BlobDB2Write(
            tokenBytes: tokenBytes,
            databaseID: databaseID,
            timestamp: timestamp,
            key: key,
            value: value
        )
    }
}

public enum BlobDB2CodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unsupportedCommand
}
