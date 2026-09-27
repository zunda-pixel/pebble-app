import Foundation

/// `CommonTimelineItemHeader` (`services/timeline/item.h`), then the payload
/// length and the attribute and action counts: what every timeline item —
/// pin, reminder or notification — starts with.
struct TimelineItemHeader {
    static let length = 46

    var id: UUID
    var parentApplicationID: UUID
    var timestamp: UInt32
    var durationMinutes: UInt16
    var kind: TimelineItemKind
    var flags: UInt16
    /// `LayoutId` (`services/timeline/layout_layer.h`).
    var layout: UInt8
    var payloadLength: UInt16
    var attributeCount: UInt8
    var actionCount: UInt8

    var encoded: [UInt8] {
        var bytes = id.bytes
        bytes += parentApplicationID.bytes
        bytes += timestamp.littleEndianBytes
        bytes += durationMinutes.littleEndianBytes
        bytes.append(kind.rawValue)
        bytes += flags.littleEndianBytes
        bytes.append(layout)
        bytes += payloadLength.littleEndianBytes
        bytes.append(attributeCount)
        bytes.append(actionCount)
        return bytes
    }

    static func textAttribute(id: UInt8, value: String, maximumByteCount: Int) -> [UInt8] {
        let content = value.utf8BytesEndingOnACharacter(maximumByteCount: maximumByteCount)
        return [id] + UInt16(content.count).littleEndianBytes + content
    }
}
