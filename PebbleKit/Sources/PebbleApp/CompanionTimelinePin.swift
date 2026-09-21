import CryptoKit
import Foundation
import PebbleProtocol

/// A timeline pin as a watch app's JavaScript writes it: the timeline web
/// API's own JSON, the shape every published watchface already speaks
/// (`Pebble.insertTimelinePin`). Only what this app's pins can carry is read —
/// a layout this app cannot draw still keeps its words, because every pin
/// this app sends the watch is rendered generic anyway.
struct CompanionTimelinePin: Equatable, Sendable {
    var backingID: String
    var time: Date
    var durationMinutes: Int
    var title: String
    var subtitle: String?
    var body: String?

    enum ParseError: Error, Equatable {
        case unreadable
        /// The web API requires `id`, `time` and a layout; a pin without them
        /// is not a pin that can be placed or deleted later.
        case missingEssentials
        /// A pin with no words at all would render as an empty card.
        case nothingToShow
    }

    /// Reads the JSON a script handed to `insertTimelinePin`.
    static func parse(_ json: String) throws -> CompanionTimelinePin {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ParseError.unreadable
        }
        guard let backingID = (object["id"] as? String)?.emptyAsAbsent,
              let timeString = object["time"] as? String,
              let time = webDate(timeString),
              let layout = object["layout"] as? [String: Any] else {
            throw ParseError.missingEssentials
        }
        let title = (layout["title"] as? String)?.emptyAsAbsent
            ?? (layout["shortTitle"] as? String)?.emptyAsAbsent
        guard let title else { throw ParseError.nothingToShow }
        return CompanionTimelinePin(
            backingID: backingID,
            time: time,
            durationMinutes: max(0, object["duration"] as? Int ?? 0),
            title: title,
            subtitle: (layout["subtitle"] as? String)?.emptyAsAbsent
                ?? (layout["shortSubtitle"] as? String)?.emptyAsAbsent,
            body: (layout["body"] as? String)?.emptyAsAbsent
        )
    }

    /// The web API writes ISO 8601, with or without fractional seconds.
    private static func webDate(_ string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: .iso8601))
    }

    /// One stable identifier per (application, pin id), so inserting the same
    /// pin twice updates it and a later delete finds it — across launches,
    /// which is why this is a digest and not a lookup table.
    static func pinID(applicationID: UUID, backingID: String) -> UUID {
        let digest = SHA256.hash(data: Data("timeline-pin:\(applicationID.uuidString.lowercased()):\(backingID)".utf8))
        var bytes = Array(digest.prefix(16))
        // Stamped as a version-8 (custom) RFC 9562 UUID, so it can never
        // collide with the random version-4 ones the rest of the app mints.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The pin as this app keeps pins, owned by the application that pushed it.
    func timelinePin(applicationID: UUID) -> TimelinePin {
        TimelinePin(
            id: Self.pinID(applicationID: applicationID, backingID: backingID),
            parentApplicationID: applicationID,
            timestamp: time,
            durationMinutes: UInt16(clamping: durationMinutes),
            title: title,
            subtitle: subtitle,
            body: body
        )
    }
}

private extension String {
    /// The web API sends "" as readily as it omits a key; both mean absent.
    var emptyAsAbsent: String? { isEmpty ? nil : self }
}
