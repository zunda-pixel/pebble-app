package enum WatchAdvertisement {
    package static var vendorIdentifiers: Set<UInt16> { [0x0154, 0x0EEA] }

    /// What an advertisement says about the watch behind it.
    package struct AdvertisedWatch: Equatable, Sendable {
        /// A best guess for display only: the real one arrives with the version
        /// response once connected. Nil when the advertisement does not say —
        /// a watch just reset advertises a generic name and may omit the
        /// extended record — rather than some model picked for it, which the
        /// scan list then showed with another watch's name and picture.
        package var model: WatchModel?
    }

    /// Nil for anything that is not a Pebble, or a Pebble this app cannot
    /// drive; a Pebble whose model is unknown is still one.
    package static func watch(
        advertisesPebbleService: Bool,
        localName: String?,
        manufacturerData: [UInt8]
    ) -> AdvertisedWatch? {
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
            guard let model = WatchModel(hardwarePlatform: manufacturerData[hardwarePlatformOffset]) else {
                return nil
            }
            return AdvertisedWatch(model: model)
        }
        return AdvertisedWatch(model: model(fromName: localName))
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
