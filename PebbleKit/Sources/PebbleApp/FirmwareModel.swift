public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// A firmware update: what is published, what has been downloaded, and where a
/// started install got to.
@MainActor
@Observable
public final class FirmwareModel {
    public internal(set) var journal: FirmwareUpdateJournal?
    public internal(set) var requiresConfirmation = false
    public internal(set) var availableRelease: PebbleOSFirmwareRelease?
    public internal(set) var downloaded: DownloadedFirmware?
    public internal(set) var feedback: FeatureFeedback?
}
