/// The screen has two bits a channel, so there are sixty-four colours and no
/// more; one is stored as those six bits with the two alpha bits set.
public struct PebbleColor: Codable, Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = min(red, 3)
        self.green = min(green, 3)
        self.blue = min(blue, 3)
    }

    public init?(argb: UInt8) {
        // The two top bits are the alpha, and an item's colour is always opaque.
        guard argb & 0b1100_0000 == 0b1100_0000 else { return nil }
        self.init(red: (argb >> 4) & 0x3, green: (argb >> 2) & 0x3, blue: argb & 0x3)
    }

    public var argb: UInt8 {
        0b1100_0000 | (red << 4) | (green << 2) | blue
    }

    /// The nearest colour the screen can show to one given as sRGB channels of
    /// zero to one.
    ///
    /// The four levels of a channel are evenly spaced, so rounding each channel
    /// on its own also lands on the nearest of the sixty-four.
    public init(nearestTo red: Double, green: Double, blue: Double) {
        self.init(red: Self.level(red), green: Self.level(green), blue: Self.level(blue))
    }

    private static func level(_ value: Double) -> UInt8 {
        // Written as two exits rather than a clamp so that a value which is not
        // a number lands on zero instead of trapping the conversion.
        guard value > 0 else { return 0 }
        guard value < 1 else { return 3 }
        return UInt8((value * 3).rounded())
    }

    /// Each channel spread back over the whole range: 0, 85, 170, 255.
    public var components: (red: Double, green: Double, blue: Double) {
        (Double(red) / 3, Double(green) / 3, Double(blue) / 3)
    }

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
