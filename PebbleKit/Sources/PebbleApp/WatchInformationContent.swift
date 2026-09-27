import PebbleProtocol
import SwiftUI

/// What a watch is, on a page of its own.
///
/// The facts here hardly change while the app is open: a watch's model, the
/// serial written at the factory, the hardware revision beside it, and the
/// firmware it runs. They sat in the `Watch` section above the battery and the connection state, which
/// do change — so a section named for the watch was half identity and half
/// status, and the two halves are read for different reasons. A reader wants
/// the battery at a glance and the serial once, when something has gone wrong
/// and a form is asking for it.
///
/// Takes the four values rather than a closure, unlike every other page pushed
/// from a watch's screen: those need `AppModel` to do something, and this only
/// needs what the screen pushing it already holds.
struct WatchInformationContent: View {
    var model: WatchModel?
    var serialNumber: String?
    /// Nil on a watch that never had one written, which is every watch that has
    /// not been through the factory step that writes it.
    var hardwareRevision: String?
    /// The PebbleOS version the watch is running. Software Update is where it
    /// is changed; this is where it is read alongside the rest of what the
    /// watch is. Nil until a connection reports it.
    var firmwareVersion: String?

    /// Whether there is anything here worth pushing a page for.
    ///
    /// A watch seen in a scan and never connected knows none of these: the
    /// model comes from the connection or from what was remembered, and both
    /// are absent. The row that leads here is left out in that case rather than
    /// opening an empty page.
    static func hasAnything(
        model: WatchModel?,
        serialNumber: String?,
        hardwareRevision: String?,
        firmwareVersion: String?
    ) -> Bool {
        model != nil || serialNumber != nil || hardwareRevision != nil || firmwareVersion != nil
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
            if let firmwareVersion {
                Section("Software") {
                    // A version is a version in any language, so it is not
                    // translated.
                    LabeledContent("Version") { Text(verbatim: firmwareVersion) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("About"))
    }
}

#Preview("Everything known") {
    NavigationStack {
        WatchInformationContent(
            model: .pebbleTime2,
            serialNumber: "Q402P000000A",
            hardwareRevision: "V2R2",
            firmwareVersion: "v4.38.1"
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
            hardwareRevision: nil,
            firmwareVersion: nil
        )
    }
}
