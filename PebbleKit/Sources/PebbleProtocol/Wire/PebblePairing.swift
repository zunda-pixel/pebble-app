import MemberwiseInit

/// A watch that is not bonded yet reports `isPaired` false, and a bond the
/// phone has forgotten shows as paired but unencrypted.
@MemberwiseInit(.package)
package struct PebbleConnectivityStatus: Equatable, Sendable {
    package var isConnected: Bool
    package var isPaired: Bool
    package var isEncrypted: Bool
    package var hasBondedGateway: Bool
    package var supportsPinningWithoutSlaveSecurity: Bool
    package var hasRemoteAttemptedToUseStalePairing: Bool
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
            hasRemoteAttemptedToUseStalePairing: flags & 0b10_0000 != 0,
            pairingError: bytes[3]
        )
    }

    package var isReadyForProtocol: Bool {
        isPaired && isEncrypted
    }
}

package enum PebblePairingTrigger {
    /// The default asks the watch to start the security request itself, which is
    /// what makes iOS show its pairing prompt.
    package static func value(
        pinAddress: Bool = false,
        noSecurityRequest: Bool = false,
        autoAcceptFuturePairing: Bool = false,
        watchAsGattServer: Bool = false
    ) -> [UInt8] {
        var flags: UInt8 = 0
        if pinAddress { flags |= 1 << 0 }
        if noSecurityRequest { flags |= 1 << 1 }
        // The watch only sends a security request when told to.
        if !noSecurityRequest { flags |= 1 << 2 }
        if autoAcceptFuturePairing { flags |= 1 << 3 }
        if watchAsGattServer { flags |= 1 << 4 }
        return [flags]
    }
}
