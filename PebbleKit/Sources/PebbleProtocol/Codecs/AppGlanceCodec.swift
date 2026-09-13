public import Foundation
import MemberwiseInit

/// A line the launcher shows under a watchapp's name, so that the reader does
/// not have to open it.
///
/// The subtitle is not plain text but a template the watch evaluates every time
/// it draws the line (`applib/template_string.h`), which is what lets one
/// written today still read "in 20 minutes" an hour from now:
///
///     {time_until(1788393600)|format("in %uH hours")}
///
/// Nothing is required of it, so a plain sentence is also a valid template.
@MemberwiseInit(.public)
public struct AppGlanceSlice: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var subtitleTemplate: String = ""
    /// Nil leaves the watch its own icon for the app.
    public var icon: TimelineIcon? = nil
    /// When this line stops being true. Nil for one that always is.
    ///
    /// The watch shows whichever slice expires soonest among those that have
    /// not, and falls back to a never-expiring one only when every other slice
    /// has gone (`prv_find_current_glance`). A glance whose slices have all
    /// expired shows nothing at all.
    public var expires: Date? = nil
}

/// Every line one watchapp has to show, and when they were written.
@MemberwiseInit(.public)
public struct AppGlance: Codable, Equatable, Sendable, Identifiable {
    public var applicationID: UUID
    public var slices: [AppGlanceSlice] = []
    /// The watch refuses a glance that is not newer than the one it holds, so
    /// this is the moment the reader wrote it rather than the moment it is sent.
    public var updatedAt: Date = Date()

    public var id: UUID { applicationID }
}

public enum AppGlanceCodec {
    public static var databaseID: UInt8 { 11 }

    static let recordVersion: UInt8 = 1
    static let iconAndSubtitleSlice: UInt8 = 0
    static let expirationAttribute: UInt8 = 37
    static let subtitleTemplateAttribute: UInt8 = 47
    static let iconAttribute: UInt8 = 48
    /// `APP_GLANCE_DB_MAX_SLICES_PER_GLANCE`. The watch trims what it is sent
    /// past this, saying in a comment that a phone has no way of knowing the
    /// limit. This one does.
    static let maximumSlices = 8
    /// `ATTRIBUTE_APP_GLANCE_SUBTITLE_MAX_LEN`. Longer and the watch keeps this
    /// much and drops the rest, so the cut is made here where a character can
    /// be kept whole.
    static let maximumSubtitleLength = 150

    public static func key(for applicationID: UUID) -> [UInt8] {
        BlobDBCodec.uuidBytes(applicationID)
    }

    public static func value(for glance: AppGlance) -> [UInt8] {
        var value: [UInt8] = [recordVersion]
        value.append(contentsOf: UInt32(clamping: Int(glance.updatedAt.timeIntervalSince1970)).littleEndianBytes)
        for slice in glance.slices.prefix(maximumSlices) {
            value.append(contentsOf: self.slice(slice))
        }
        return value
    }

    static func slice(_ slice: AppGlanceSlice) -> [UInt8] {
        var attributes: [[UInt8]] = [
            // Always written, even for a line that never expires: a slice with
            // no attributes at all is shorter than the smallest the watch
            // accepts, and zero is how the firmware spells "never"
            // (`APP_GLANCE_SLICE_NO_EXPIRATION`).
            attribute(
                id: expirationAttribute,
                content: UInt32(clamping: slice.expires.map { Int($0.timeIntervalSince1970) } ?? 0)
                    .littleEndianBytes
            ),
        ]
        let subtitle = trimmed(slice.subtitleTemplate)
        if !subtitle.isEmpty {
            attributes.append(attribute(id: subtitleTemplateAttribute, content: subtitle))
        }
        if let icon = slice.icon {
            attributes.append(attribute(id: iconAttribute, content: icon.resourceID.littleEndianBytes))
        }
        let body = attributes.flatMap { $0 }
        // The size counts this header as well.
        return UInt16(clamping: 4 + body.count).littleEndianBytes
            + [iconAndSubtitleSlice, UInt8(attributes.count)]
            + body
    }

    public static func insertFrame(_ glance: AppGlance, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: key(for: glance.applicationID),
            value: value(for: glance),
            token: token
        )
    }

    public static func deleteFrame(applicationID: UUID, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.deleteFrame(
            databaseID: databaseID,
            key: key(for: applicationID),
            token: token
        )
    }

    private static func attribute(id: UInt8, content: [UInt8]) -> [UInt8] {
        [id, UInt8(content.count & 0xFF), UInt8(content.count >> 8)] + content
    }

    /// The template as bytes, cut on a character rather than inside one.
    private static func trimmed(_ template: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for character in template {
            let encoded = Array(String(character).utf8)
            guard bytes.count + encoded.count <= maximumSubtitleLength else { break }
            bytes.append(contentsOf: encoded)
        }
        return bytes
    }
}
