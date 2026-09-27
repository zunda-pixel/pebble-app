import Foundation
import Observation
import SwiftUI

/// Which of the app's windows shows what the model asks to be shown.
///
/// Every window of the one `WindowGroup` reads the same `AppModel`, so a sheet
/// or an alert bound to the model's state came up in all of them at once, and
/// a menu command reached every window. One window answers for all: the one
/// the reader brought forward last, or, when that one closes, the one before.
@MainActor
@Observable
final class FrontWindow {
    static let shared = FrontWindow()

    /// Oldest first, so the last is the front one.
    private(set) var order: [UUID] = []

    func isFront(_ window: UUID) -> Bool {
        order.last == window
    }

    func bringForward(_ window: UUID) {
        guard order.last != window else { return }
        order.removeAll { $0 == window }
        order.append(window)
    }

    func close(_ window: UUID) {
        order.removeAll { $0 == window }
    }
}

extension EnvironmentValues {
    /// Which window this view is in, for `FrontWindow` to be asked about.
    @Entry var windowIdentity: UUID? = nil
}
