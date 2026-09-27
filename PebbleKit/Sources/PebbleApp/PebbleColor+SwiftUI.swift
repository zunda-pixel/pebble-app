import PebbleProtocol
import SwiftUI

extension Color {
    init(_ colour: PebbleColor) {
        let (red, green, blue) = colour.components
        self.init(red: red, green: green, blue: blue)
    }
}

extension PebbleColor {
    /// The nearest colour the watch can show to one picked on the phone.
    ///
    /// The picked colour is read back as sRGB rather than the linear values
    /// `Color.Resolved` stores, because the watch's four levels a channel are
    /// steps of the sRGB one — rounding the linear value would darken it.
    init(nearest colour: Color, in environment: EnvironmentValues) {
        let resolved = colour.resolveHDR(in: environment)
        self.init(
            nearestTo: Double(resolved.red),
            green: Double(resolved.green),
            blue: Double(resolved.blue)
        )
    }
}

extension Color {
    /// The backlight LED's colour, from the firmware's packed `0x00RRGGBB`.
    init(packedRGB: Int) {
        self.init(
            red: Double((packedRGB >> 16) & 0xFF) / 255,
            green: Double((packedRGB >> 8) & 0xFF) / 255,
            blue: Double(packedRGB & 0xFF) / 255
        )
    }

    /// The picked colour as the firmware packs it. Read back as sRGB rather
    /// than the linear values `Color.Resolved` stores, for the same reason
    /// `PebbleColor.init(nearest:in:)` does: the wire carries display values,
    /// and rounding linear ones would darken the colour.
    func packedRGB(in environment: EnvironmentValues) -> Int {
        let resolved = resolveHDR(in: environment)
        func channel(_ value: Float) -> Int {
            min(255, max(0, Int((Double(value) * 255).rounded())))
        }
        return channel(resolved.red) << 16 | channel(resolved.green) << 8
            | channel(resolved.blue)
    }
}
