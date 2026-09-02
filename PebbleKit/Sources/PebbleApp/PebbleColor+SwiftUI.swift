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
