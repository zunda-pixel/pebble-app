import MemberwiseInit

@MemberwiseInit
struct PPoGTransmission: Sendable {
    var packet: PPoGPacket
    var attemptCount: Int
}

public enum PPoGSessionAction: Equatable, Sendable {
    case send(PPoGPacket)
    case deliver([UInt8])
    case resetRequired
}

@MemberwiseInit(.public)
public struct PPoGSession: Sendable {
    public var receiveWindow: Int = 25
    public var transmitWindow: Int = 25

    @Init(.ignore) private var nextOutboundSequence = 0
    @Init(.ignore) private var expectedInboundSequence = 0
    @Init(.ignore) private var queuedTransmissions: [PPoGTransmission] = []
    @Init(.ignore) private var inFlightTransmissions: [PPoGTransmission] = []
    @Init(.ignore) private var lastSentAcknowledgement: PPoGPacket?
    @Init(.ignore) private var lastReceivedAcknowledgementSequence: Int?

    /// Bytes each data packet spends on its own header. The watch sizes its
    /// receive buffers to the negotiated packet size minus this much, so a
    /// smaller allowance here produces packets it quietly drops.
    static let headerOverhead = 4

    public var hasPendingAcknowledgements: Bool {
        !inFlightTransmissions.isEmpty
    }

    public mutating func enqueue(
        _ bytes: [UInt8],
        maximumPacketSize: Int
    ) throws -> [PPoGSessionAction] {
        guard maximumPacketSize > Self.headerOverhead else {
            throw PPoGSessionError.invalidMaximumPacketSize
        }

        let maximumPayloadSize = maximumPacketSize - Self.headerOverhead
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + maximumPayloadSize, bytes.count)
            let packet = PPoGPacket.data(
                sequence: nextOutboundSequence,
                payload: Array(bytes[offset..<end])
            )
            queuedTransmissions.append(
                PPoGTransmission(packet: packet, attemptCount: 0)
            )
            nextOutboundSequence = (nextOutboundSequence + 1) % 32
            offset = end
        }

        return drainSendWindow()
    }

    public mutating func receive(_ packet: PPoGPacket) throws -> [PPoGSessionAction] {
        switch packet {
        case .acknowledgement(let sequence):
            if lastReceivedAcknowledgementSequence == sequence {
                return inFlightTransmissions.map { .send($0.packet) }
            }

            lastReceivedAcknowledgementSequence = sequence
            guard let acknowledgedIndex = inFlightTransmissions.firstIndex(where: {
                $0.packet.sequence == sequence
            }) else {
                return []
            }

            inFlightTransmissions.removeFirst(acknowledgedIndex + 1)
            return drainSendWindow()

        case .data(let sequence, let payload):
            guard sequence == expectedInboundSequence else {
                guard let lastSentAcknowledgement else {
                    return []
                }
                return [.send(lastSentAcknowledgement)]
            }

            expectedInboundSequence = (expectedInboundSequence + 1) % 32
            let acknowledgement = PPoGPacket.acknowledgement(sequence: sequence)
            lastSentAcknowledgement = acknowledgement
            return [.deliver(payload), .send(acknowledgement)]

        case .resetRequest, .resetComplete:
            return [.resetRequired]
        }
    }

    public mutating func handleAcknowledgementTimeout() throws -> [PPoGSessionAction] {
        for index in inFlightTransmissions.indices {
            inFlightTransmissions[index].attemptCount += 1
            guard inFlightTransmissions[index].attemptCount <= 2 else {
                throw PPoGSessionError.maximumRetriesExceeded
            }
        }
        return inFlightTransmissions.map { .send($0.packet) }
    }

    private mutating func drainSendWindow() -> [PPoGSessionAction] {
        var actions: [PPoGSessionAction] = []
        while inFlightTransmissions.count < transmitWindow,
              !queuedTransmissions.isEmpty {
            let transmission = queuedTransmissions.removeFirst()
            inFlightTransmissions.append(transmission)
            actions.append(.send(transmission.packet))
        }
        return actions
    }
}

public extension PPoGPacket {
    var sequence: Int {
        switch self {
        case .data(let sequence, _),
             .acknowledgement(let sequence),
             .resetRequest(let sequence, _),
             .resetComplete(let sequence, _, _):
            sequence
        }
    }
}

public enum PPoGSessionError: Error, Equatable, Sendable {
    case invalidMaximumPacketSize
    case maximumRetriesExceeded
}
