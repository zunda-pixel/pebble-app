/// A colour the watch can show.
///
/// The screen has two bits a channel, so there are sixty-four of them and no
/// more; a colour is stored as those six bits with the two alpha bits set,
/// which is the firmware's `GColor8`.
public struct PebbleColor: Codable, Equatable, Hashable, Sendable {
    /// Nothing but 0, 1, 2 or 3 in each: the screen has no room for anything
    /// between.
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = min(red, 3)
        self.green = min(green, 3)
        self.blue = min(blue, 3)
    }

    public init?(argb: UInt8) {
        // The two top bits are the alpha, and an item's colour is always
        // opaque; anything else is not a colour this app wrote.
        guard argb & 0b1100_0000 == 0b1100_0000 else { return nil }
        self.init(red: (argb >> 4) & 0x3, green: (argb >> 2) & 0x3, blue: argb & 0x3)
    }

    /// What goes on the wire.
    public var argb: UInt8 {
        0b1100_0000 | (red << 4) | (green << 2) | blue
    }

    /// Each channel spread back over the whole range, for showing the colour on
    /// a screen that has more of them: 0, 85, 170, 255.
    public var components: (red: Double, green: Double, blue: Double) {
        (Double(red) / 3, Double(green) / 3, Double(blue) / 3)
    }

    /// Every colour the watch has, ordered so that they lay out as four blocks
    /// of increasing red.
    public static let all: [PebbleColor] = (0..<4).flatMap { red in
        (0..<4).flatMap { green in
            (0..<4).map { blue in
                PebbleColor(red: UInt8(red), green: UInt8(green), blue: UInt8(blue))
            }
        }
    }

    public static let black = PebbleColor(red: 0, green: 0, blue: 0)
    public static let white = PebbleColor(red: 3, green: 3, blue: 3)
}
