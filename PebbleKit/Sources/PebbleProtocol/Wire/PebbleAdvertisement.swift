package enum PebbleAdvertisement {
    package static var vendorIdentifiers: Set<UInt16> { [0x0154, 0x0EEA] }

    /// The model is a best guess for display only: the real one arrives with the
    /// version response once connected.
    package static func model(
        advertisesPebbleService: Bool,
        localName: String?,
        manufacturerData: [UInt8]
    ) -> WatchModel? {
        let containsCompanyIdentifier = manufacturerData.count >= 2
            && vendorIdentifiers.contains(
                UInt16(manufacturerData[0]) | UInt16(manufacturerData[1]) << 8
            )
        guard containsCompanyIdentifier || advertisesPebbleService else {
            return nil
        }

        // Payload: type(1) + serial(12), then an extended record whose first byte is
        // the hardware platform. Older firmware omits it, and platform 0 means the
        // watch did not say.
        let hardwarePlatformOffset = (containsCompanyIdentifier ? 2 : 0) + 13
        if manufacturerData.indices.contains(hardwarePlatformOffset),
           manufacturerData[hardwarePlatformOffset] != 0 {
            // A watch that names its platform is trusted, even when that means rejecting
            // a model this app cannot drive.
            return WatchModel(hardwarePlatform: manufacturerData[hardwarePlatformOffset])
        }
        return model(fromName: localName) ?? .pebbleTime2
    }

    static func model(fromName name: String?) -> WatchModel? {
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
