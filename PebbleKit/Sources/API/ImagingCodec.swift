public import Foundation
import MemberwiseInit

public enum PebbleImageKind: UInt8, Equatable, Sendable {
    case albumArt = 0
    case notification = 1
}

/// The watch pulls rather than the phone pushing: it asks when it has
/// somewhere to show the picture and knows how big that is.
public enum PebbleImageRequest: Equatable, Sendable {
    case albumArt(PebbleImageRequestHeader, title: String, artist: String)
    case notification(PebbleImageRequestHeader, itemID: UUID)
    /// A kind this app has never heard of still has a token, and the watch waits
    /// on that token until it is told there is nothing coming.
    case unsupported(PebbleImageRequestHeader)

    public var header: PebbleImageRequestHeader {
        switch self {
        case .albumArt(let header, _, _), .notification(let header, _), .unsupported(let header):
            header
        }
    }
}

@MemberwiseInit(.public)
public struct PebbleImageRequestHeader: Equatable, Sendable {
    public var token: UInt8
    public var kindValue: UInt8
    public var format: UInt8
    public var width: Int
    public var height: Int

    public var kind: PebbleImageKind? { PebbleImageKind(rawValue: kindValue) }
}

@MemberwiseInit(.public)
public struct PebbleEncodedImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var palette: [UInt8]
    /// Four-bit indices into the palette, the even column in the high nibble,
    /// each row padded out to a whole byte.
    public var pixels: [UInt8]
}

public enum ImagingCodec {
    public static var endpoint: UInt16 { 53 }

    static let requestCommand: UInt8 = 0x01
    static let responseCommand: UInt8 = 0x02

    static let firstChunkFlag: UInt8 = 0x01
    static let lastChunkFlag: UInt8 = 0x02
    static let noImageFlag: UInt8 = 0x04
    static let unsupportedFlag: UInt8 = 0x08

    /// The watch clamps what it asks for to this; a request outside it is answered
    /// with nothing rather than trusted.
    public static let maximumDimension = 300
    /// Keeps a chunk near a kilobyte.
    static let pixelsPerChunk = 1_000

    public static func decode(_ frame: PebbleProtocolFrame) throws -> PebbleImageRequest {
        guard frame.endpoint == endpoint else { throw ImagingCodecError.unexpectedEndpoint }
        guard frame.payload.count >= 8, frame.payload[0] == requestCommand else {
            throw ImagingCodecError.invalidPayload
        }
        let header = PebbleImageRequestHeader(
            token: frame.payload[1],
            kindValue: frame.payload[2],
            format: frame.payload[3],
            width: Int(frame.payload[4]) | Int(frame.payload[5]) << 8,
            height: Int(frame.payload[6]) | Int(frame.payload[7]) << 8
        )
        var offset = 8
        switch header.kind {
        case .albumArt:
            let title = try string(frame.payload, at: &offset)
            let artist = try string(frame.payload, at: &offset)
            return .albumArt(header, title: title, artist: artist)
        case .notification:
            guard frame.payload.count >= offset + 16 else { throw ImagingCodecError.invalidPayload }
            let hex = frame.payload[offset..<offset + 16].hexadecimalString
            let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
            guard let id = UUID(uuidString: formatted) else { throw ImagingCodecError.invalidPayload }
            return .notification(header, itemID: id)
        case nil:
            return .unsupported(header)
        }
    }

    public static func responseFrames(
        token: UInt8,
        kindValue: UInt8,
        image: PebbleEncodedImage?
    ) -> [PebbleProtocolFrame] {
        guard let image, !image.pixels.isEmpty else {
            return [flagsFrame(token: token, kindValue: kindValue, flags: noImageFlag)]
        }
        var header: [UInt8] = UInt16(image.width).littleEndianBytes
        header += UInt16(image.height).littleEndianBytes
        // Format 2: four bits a pixel, into the palette that follows.
        header.append(0x02)
        header.append(UInt8(image.palette.count))
        header += image.palette

        var frames: [PebbleProtocolFrame] = []
        var offset = 0
        while offset < image.pixels.count {
            let count = min(pixelsPerChunk, image.pixels.count - offset)
            var flags: UInt8 = 0
            if offset == 0 { flags |= firstChunkFlag }
            if offset + count >= image.pixels.count { flags |= lastChunkFlag }
            var payload: [UInt8] = [responseCommand, token, flagsByte(kindValue: kindValue, flags: flags)]
            payload += UInt32(offset).littleEndianBytes
            payload += UInt16(count).littleEndianBytes
            if offset == 0 { payload += header }
            payload += image.pixels[offset..<offset + count]
            frames.append(PebbleProtocolFrame(endpoint: endpoint, payload: payload))
            offset += count
        }
        return frames
    }

    public static func unsupportedFrame(token: UInt8, kindValue: UInt8) -> PebbleProtocolFrame {
        flagsFrame(token: token, kindValue: kindValue, flags: unsupportedFlag)
    }

    public static func noImageFrame(token: UInt8, kindValue: UInt8) -> PebbleProtocolFrame {
        flagsFrame(token: token, kindValue: kindValue, flags: noImageFlag)
    }

    static func flagsFrame(token: UInt8, kindValue: UInt8, flags: UInt8) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [responseCommand, token, flagsByte(kindValue: kindValue, flags: flags), 0, 0, 0, 0, 0, 0]
        )
    }

    // The watch can have several requests out at once, and the token alone does
    // not say which one an answer is for.
    static func flagsByte(kindValue: UInt8, flags: UInt8) -> UInt8 {
        flags | ((kindValue & 0x0F) << 4)
    }

    private static func string(_ payload: [UInt8], at offset: inout Int) throws -> String {
        guard payload.count > offset else { throw ImagingCodecError.invalidPayload }
        let length = Int(payload[offset])
        offset += 1
        guard payload.count >= offset + length else { throw ImagingCodecError.invalidPayload }
        let value = String(decoding: payload[offset..<offset + length], as: UTF8.self)
        offset += length
        return value
    }
}

public enum ImagingCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
}
