public enum PebbleAdvertisement {
    /// Manufacturer identifiers used by Pebble and Core Devices watches.
    public static var vendorIdentifiers: Set<UInt16> { [0x0154, 0x0EEA] }

    /// Decides whether a scan result belongs to a Pebble we can talk to, and
    /// returns the model to show for it.
    ///
    /// The model is a best guess for display only: the real one arrives with
    /// the watch version right after connecting. A watch that has just been
    /// reset advertises a generic name and may omit the extended scan record,
    /// so an unrecognisable model must not hide it from the list.
    public static func model(
        advertisesPebbleService: Bool,
        localName: String?,
        manufacturerData: [UInt8]
    ) -> PebbleWatchModel? {
        let containsCompanyIdentifier = manufacturerData.count >= 2
            && vendorIdentifiers.contains(
                UInt16(manufacturerData[0]) | UInt16(manufacturerData[1]) << 8
            )
        guard containsCompanyIdentifier || advertisesPebbleService else {
            return nil
        }

        // Payload: type(1) + serial(12), then the extended record whose first
        // byte is the hardware platform. Older firmware omits the extension,
        // and platform 0 means the watch did not report one.
        let hardwarePlatformOffset = (containsCompanyIdentifier ? 2 : 0) + 13
        if manufacturerData.indices.contains(hardwarePlatformOffset),
           manufacturerData[hardwarePlatformOffset] != 0 {
            // A watch that names its platform is trusted, even when that means
            // rejecting a model this app cannot drive.
            return PebbleWatchModel(hardwarePlatform: manufacturerData[hardwarePlatformOffset])
        }
        return model(fromName: localName) ?? .pebbleTime2
    }

    static func model(fromName name: String?) -> PebbleWatchModel? {
        guard let normalizedName = name?.lowercased() else {
            return nil
        }
        if normalizedName.contains("duo") {
            return .pebble2Duo
        }
        if normalizedName.contains("round 2") {
            return .pebbleRound2
        }
        if normalizedName.contains("time 2") {
            return .pebbleTime2
        }
        return nil
    }
}
