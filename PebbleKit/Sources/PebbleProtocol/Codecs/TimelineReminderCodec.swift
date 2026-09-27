public import Foundation

/// The watch keeps a window of reminders around the present and shows each one
/// when its time comes, rather than listing it on the timeline.
public enum TimelineReminderCodec {
    public static var databaseID: UInt8 { 0x03 }

    public static func insertFrame(
        _ reminder: TimelinePin,
        token: UInt16
    ) throws -> PebbleProtocolFrame {
        var reminder = reminder
        reminder.kind = .reminder
        return try BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: reminder.id.bytes,
            value: try reminder.encoded(),
            token: token
        )
    }

    public static func deleteFrame(id: UUID, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedDeleteFrame(databaseID: databaseID, key: id.bytes, token: token)
    }
}
