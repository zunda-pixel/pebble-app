import MemberwiseInit

/// A watch that is not bonded yet reports `isPaired` false, and a bond the
/// phone has forgotten shows as paired but unencrypted.
@MemberwiseInit(.package)
package struct ConnectivityStatus: Equatable, Sendable {
    package var isConnected: Bool
    package var isPaired: Bool
    package var isEncrypted: Bool
    package var hasBondedGateway: Bool
    package var supportsPinningWithoutSlaveSecurity: Bool
    // The reference app calls bit 5 "remote attempted to use stale pairing";
    // the firmware's is `is_reversed_ppogatt_enabled`
    // (`pbl_bt_pps_connectivity_status`, `bluetooth/pebble_pairing_service.h`),
    // and `pebble_pairing_service.c` never sets it, so it cannot signal a
    // forgotten bond.
    package var isReversedPPoGATTEnabled: Bool
    package var pairingError: UInt8

    // A healthy watch always reports four bytes: flags, two reserved bytes and a
    // pairing error code.
    package init?(decoding bytes: [UInt8]) {
        guard bytes.count >= 4 else {
            return nil
        }
        let flags = bytes[0]
        self.init(
            isConnected: flags & 0b1 != 0,
            isPaired: flags & 0b10 != 0,
            isEncrypted: flags & 0b100 != 0,
            hasBondedGateway: flags & 0b1000 != 0,
            supportsPinningWithoutSlaveSecurity: flags & 0b1_0000 != 0,
            isReversedPPoGATTEnabled: flags & 0b10_0000 != 0,
            pairingError: bytes[3]
        )
    }

    package var isReadyForProtocol: Bool {
        isPaired && isEncrypted
    }
}

package enum PairingTrigger {
    /// The default asks the watch to start the security request itself, which is
    /// what makes iOS show its pairing prompt.
    package static func value(
        pinAddress: Bool = false,
        noSecurityRequest: Bool = false,
        watchAsGattServer: Bool = false
    ) -> [UInt8] {
        var flags: UInt8 = 0
        if pinAddress { flags |= 1 << 0 }
        if noSecurityRequest { flags |= 1 << 1 }
        // The watch only sends a security request when told to.
        if !noSecurityRequest { flags |= 1 << 2 }
        if watchAsGattServer { flags |= 1 << 4 }
        return [flags]
    }
}
