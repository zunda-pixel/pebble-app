public import Foundation

public enum RemindersAppState: UInt8, Codable, Equatable, Sendable {
    case notEnabled = 0
    case notConfigured = 1
    case enabled = 2
}

/// `BlobDBIdWatchAppPrefs` (`services/blob_db/api.h`): one database the system
/// watch apps share, each reading the record under its own literal key. The
/// firmware compares the key to the literal it holds, so it is not a UUID.
public enum WatchAppPreferencesCodec {
    public static var databaseID: UInt8 { 9 }

    public static var weatherKey: String { "weatherApp" }
    public static var remindersKey: String { "remindersApp" }

    /// Writing a forecast is not enough on its own: the weather app walks this
    /// list and skips any forecast whose key is not in it.
    public static func weatherOrderValue(orderedIDs: [UUID]) -> [UInt8] {
        // `num_locations` is one byte and the firmware checks the length against it.
        let ids = orderedIDs.prefix(Int(UInt8.max))
        return [UInt8(ids.count)] + ids.flatMap { $0.bytes }
    }

    public static func weatherOrderFrame(orderedIDs: [UUID], token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedInsertFrame(
            databaseID: databaseID,
            key: Array(weatherKey.utf8),
            value: weatherOrderValue(orderedIDs: orderedIDs),
            token: token
        )
    }

    public static func remindersAppFrame(state: RemindersAppState, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedInsertFrame(
            databaseID: databaseID,
            key: Array(remindersKey.utf8),
            value: [state.rawValue],
            token: token
        )
    }
}
