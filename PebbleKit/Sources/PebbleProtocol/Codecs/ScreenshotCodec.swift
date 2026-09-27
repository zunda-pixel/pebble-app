import MemberwiseInit

@MemberwiseInit(.public)
public struct WatchScreenshot: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// One pixel per entry, row by row, as `0xAARRGGBB`.
    public var pixels: [UInt32]
}

public enum ScreenshotCodec {
    public static var endpoint: UInt16 { 8_000 }

    public static func requestFrame() -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x00])
    }
}

/// There is no marker on the last packet, so the pixels are counted against
/// the size in the header.
public struct ScreenshotCollector: WatchPullCollector {
    /// One bit a pixel on a black and white screen, one byte on a color one.
    enum Depth: UInt32 {
        case blackAndWhite = 1
        case color = 2

        var bitsPerPixel: Int { self == .blackAndWhite ? 1 : 8 }
    }

    private var width = 0
    private var height = 0
    private var depth = Depth.color
    private var expectedByteCount = 0
    private var bytes: [UInt8] = []
    private var hasHeader = false

    public init() {}

    public mutating func accept(_ frame: PebbleProtocolFrame) throws -> WatchScreenshot? {
        guard frame.endpoint == ScreenshotCodec.endpoint else {
            throw ScreenshotError.unexpectedEndpoint
        }
        var payload = frame.payload
        if !hasHeader {
            guard payload.count >= 13 else { throw ScreenshotError.invalidPayload }
            let response = payload[0]
            guard response == 0 else { throw ScreenshotError.refused(response) }
            // The header counts in network order, unlike the pixels that follow.
            let version = UInt32(bigEndianBytes: Array(payload[1..<5]))
            width = Int(UInt32(bigEndianBytes: Array(payload[5..<9])))
            height = Int(UInt32(bigEndianBytes: Array(payload[9..<13])))
            guard let depth = Depth(rawValue: version) else {
                throw ScreenshotError.unsupportedVersion(version)
            }
            guard width > 0, height > 0, width <= 1_000, height <= 1_000 else {
                throw ScreenshotError.invalidPayload
            }
            self.depth = depth
            expectedByteCount = width * height * depth.bitsPerPixel / 8
            hasHeader = true
            payload = Array(payload.dropFirst(13))
        }
        bytes += payload
        guard bytes.count >= expectedByteCount else { return nil }
        return picture()
    }

    private func picture() -> WatchScreenshot {
        var pixels = [UInt32](repeating: 0, count: width * height)
        switch depth {
        case .blackAndWhite:
            // A row is padded to whole bytes, and the leftmost pixel is the lowest bit
            // of the first one.
            let stride = width / 8
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * stride + x / 8
                    guard index < bytes.count else { continue }
                    let isLit = (bytes[index] >> (x % 8)) & 1 == 1
                    pixels[y * width + x] = isLit ? 0xFFFF_FFFF : 0xFF00_0000
                }
            }
        case .color:
            for index in 0..<min(pixels.count, bytes.count) {
                pixels[index] = Self.color(bytes[index])
            }
        }
        return WatchScreenshot(width: width, height: height, pixels: pixels)
    }

    // Two bits a channel, spread over the whole range.
    static func color(_ value: UInt8) -> UInt32 {
        let red = UInt32((value >> 4) & 0x3) * 85
        let green = UInt32((value >> 2) & 0x3) * 85
        let blue = UInt32(value & 0x3) * 85
        return 0xFF00_0000 | (red << 16) | (green << 8) | blue
    }
}

public enum ScreenshotError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unsupportedVersion(UInt32)
    /// One means the watch did not understand the request, two that it had no
    /// memory to spare, three that it is already sending one.
    case refused(UInt8)
}
