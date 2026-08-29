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

/// An iOS app that produces notifications, as tracked by the watch's ANCS
/// filtering database. The watch inserts records for apps it sees; the phone
/// syncs mute preferences back.
@MemberwiseInit(.public)
public struct NotificationSourceApp: Codable, Equatable, Sendable, Identifiable {
    public var bundleID: String
    public var displayName: String
    public var muteState: NotificationAppMuteState = .never
    public var muteExpiration: Date? = nil
    public var stateUpdated: Date = .now

    public var id: String { bundleID }
}

public enum NotificationAppsCodec {
    public static var databaseID: UInt8 { 6 }

    static let appNameAttribute: UInt8 = 30
    static let lastUpdatedAttribute: UInt8 = 14
    static let muteDayOfWeekAttribute: UInt8 = 40
    static let muteExpirationAttribute: UInt8 = 50
    static let maximumNameLength = 40

    public static func key(for app: NotificationSourceApp) -> [UInt8] {
        Array(app.bundleID.utf8)
    }

    public static func value(for app: NotificationSourceApp) -> [UInt8] {
        var value: [UInt8] = UInt32(0).littleEndianBytes
        value.append(4)
        value.append(0)
        value.append(contentsOf: attribute(id: appNameAttribute, content: trimmedName(app.displayName)))
        value.append(contentsOf: attribute(id: muteDayOfWeekAttribute, content: [app.muteState.rawValue]))
        value.append(contentsOf: attribute(
            id: lastUpdatedAttribute,
            content: UInt32(clamping: Int(app.stateUpdated.timeIntervalSince1970)).littleEndianBytes
        ))
        let expiration = app.muteExpiration.map { UInt32(clamping: Int($0.timeIntervalSince1970)) } ?? 0
        value.append(contentsOf: attribute(id: muteExpirationAttribute, content: expiration.littleEndianBytes))
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
    /// Raw token bytes, echoed verbatim into the response.
    public var tokenBytes: [UInt8]
    public var databaseID: UInt8
    public var timestamp: UInt32
    public var key: [UInt8]
    public var value: [UInt8]
}

/// The watch-initiated side of BlobDB synchronization: the watch pushes its
/// own records (for example ANCS notification apps) to the phone on this
/// endpoint and expects an acknowledgement per command.
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

public actor NotificationSourceAppLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("notification-source-apps.json")
    }

    public func apps() throws -> [NotificationSourceApp] {
        try PersistentJSON.loadRecovering([NotificationSourceApp].self, from: fileURL) ?? []
    }

    public func save(_ apps: [NotificationSourceApp]) throws {
        try PersistentJSON.save(apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }, to: fileURL)
    }

    /// Applies a record written by the watch, keeping the newer state when the
    /// same app already exists locally. Returns the updated list.
    public func merge(_ app: NotificationSourceApp) throws -> [NotificationSourceApp] {
        var apps = try apps()
        if let index = apps.firstIndex(where: { $0.bundleID == app.bundleID }) {
            if app.stateUpdated > apps[index].stateUpdated {
                apps[index] = app
            }
        } else {
            apps.append(app)
        }
        try save(apps)
        return try self.apps()
    }
}
