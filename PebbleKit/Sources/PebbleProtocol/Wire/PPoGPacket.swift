package enum PPoGVersion: UInt8, Sendable {
    case zero = 0
    case one = 1

    package var supportsWindowNegotiation: Bool {
        self == .one
    }
}

package enum PPoGPacket: Equatable, Sendable {
    case data(sequence: Int, payload: [UInt8])
    case acknowledgement(sequence: Int)
    case resetRequest(sequence: Int, version: PPoGVersion)
    case resetComplete(sequence: Int, receiveWindow: UInt8, transmitWindow: UInt8)

    package init(decoding bytes: [UInt8]) throws {
        guard let header = bytes.first else {
            throw PPoGPacketError.emptyPacket
        }

        let sequence = Int((header & 0b1111_1000) >> 3)
        switch header & 0b0000_0111 {
        case 0:
            self = .data(sequence: sequence, payload: Array(bytes.dropFirst()))
        case 1:
            self = .acknowledgement(sequence: sequence)
        case 2:
            guard bytes.count >= 2, let version = PPoGVersion(rawValue: bytes[1]) else {
                throw PPoGPacketError.invalidResetRequest
            }
            self = .resetRequest(sequence: sequence, version: version)
        case 3:
            if bytes.count >= 3 {
                self = .resetComplete(
                    sequence: sequence,
                    receiveWindow: bytes[1],
                    transmitWindow: bytes[2]
                )
            } else {
                self = .resetComplete(sequence: sequence, receiveWindow: 4, transmitWindow: 4)
            }
        default:
            throw PPoGPacketError.unknownPacketType
        }
    }

    package func encoded(for version: PPoGVersion) throws -> [UInt8] {
        let sequence = try validatedSequence
        let sequenceBits = UInt8(sequence << 3)

        switch self {
        case .data(_, let payload):
            return [sequenceBits] + payload
        case .acknowledgement:
            return [sequenceBits | 1]
        case .resetRequest(_, let requestedVersion):
            return [sequenceBits | 2, requestedVersion.rawValue]
        case .resetComplete(_, let receiveWindow, let transmitWindow):
            guard version.supportsWindowNegotiation else {
                return [sequenceBits | 3]
            }
            return [sequenceBits | 3, receiveWindow, transmitWindow]
        }
    }

    private var validatedSequence: Int {
        get throws {
            let sequence: Int
            switch self {
            case .data(let value, _),
                 .acknowledgement(let value),
                 .resetRequest(let value, _),
                 .resetComplete(let value, _, _):
                sequence = value
            }

            guard (0...31).contains(sequence) else {
                throw PPoGPacketError.invalidSequence
            }
            return sequence
        }
    }
}

package enum PPoGPacketError: Error, Equatable, Sendable {
    case emptyPacket
    case invalidSequence
    case invalidResetRequest
    case unknownPacketType
}
