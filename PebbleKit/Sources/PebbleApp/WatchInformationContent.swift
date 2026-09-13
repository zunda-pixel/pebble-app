import PebbleProtocol
import SwiftUI

/// What a watch is, on a page of its own.
///
/// The three facts here do not change while the app is open: a watch's model,
/// the serial written at the factory, and the hardware revision beside it. They
/// sat in the `Watch` section above the battery and the connection state, which
/// do change — so a section named for the watch was half identity and half
/// status, and the two halves are read for different reasons. A reader wants
/// the battery at a glance and the serial once, when something has gone wrong
/// and a form is asking for it.
///
/// Takes the three values rather than a closure, unlike every other page pushed
/// from a watch's screen: those need `AppModel` to do something, and this only
/// needs what the screen pushing it already holds.
struct WatchInformationContent: View {
    var model: WatchModel?
    var serialNumber: String?
    /// Nil on a watch that never had one written, which is every watch that has
    /// not been through the factory step that writes it.
    var hardwareRevision: String?

    /// Whether there is anything here worth pushing a page for.
    ///
    /// A watch seen in a scan and never connected knows none of these: the
    /// model comes from the connection or from what was remembered, and both
    /// are absent. The row that leads here is left out in that case rather than
    /// opening an empty page.
    static func hasAnything(model: WatchModel?, serialNumber: String?, hardwareRevision: String?) -> Bool {
        model != nil || serialNumber != nil || hardwareRevision != nil
    }

    var body: some View {
        Form {
            Section {
                if let model {
                    LabeledContent("Model", value: model.displayName)
                }
                if let serialNumber {
                    LabeledContent("Serial Number", value: serialNumber)
                }
                // Beside the serial, which is where the watch itself puts it:
                // the two are adjacent fields of the version response.
                if let hardwareRevision {
                    LabeledContent("Hardware Revision", value: hardwareRevision)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("General Information"))
    }
}

#Preview("Everything known") {
    NavigationStack {
        WatchInformationContent(
            model: .pebbleTime2,
            serialNumber: "Q402P000000A",
            hardwareRevision: "V2R2"
        )
    }
}

#Preview("No hardware revision") {
    NavigationStack {
        // What a watch in the emulator looks like, and any watch whose OTP was
        // never programmed: the revision arrives as zeroes and reads as absent.
        WatchInformationContent(
            model: .pebbleTime2,
            serialNumber: nil,
            hardwareRevision: nil
        )
    }
}
