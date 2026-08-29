public import Foundation
import MemberwiseInit

public enum VoiceSessionType: UInt8, Equatable, Sendable {
    case dictation = 0x01
    case command = 0x02
}

public enum VoiceSessionResult: UInt8, Equatable, Sendable {
    case success = 0x00
    case serviceUnavailable = 0x01
    case timeout = 0x02
    case recognizerError = 0x03
    case invalidRecognizerResponse = 0x04
    case disabled = 0x05
    case invalidMessage = 0x06
}

@MemberwiseInit(.public)
public struct SpeexEncoderInfo: Equatable, Sendable {
    public var version: String
    public var sampleRate: UInt32
    public var bitRate: UInt16
    public var bitstreamVersion: UInt8
    public var frameSize: UInt16
}

@MemberwiseInit(.public)
public struct VoiceSessionSetupRequest: Equatable, Sendable {
    public var sessionType: VoiceSessionType
    public var sessionID: UInt16
    public var applicationID: UUID?
    public var encoderInfo: SpeexEncoderInfo?
}

@MemberwiseInit(.public)
public struct VoiceTranscriptionWord: Equatable, Sendable {
    public var text: String
    /// 0...1, scaled to a single byte on the wire.
    public var confidence: Double = 0.9
}

public enum VoiceControlCodec {
    public static var endpoint: UInt16 { 11_000 }

    static let speexEncoderInfoAttribute: UInt8 = 0x01
    static let transcriptionAttribute: UInt8 = 0x02
    static let applicationIDAttribute: UInt8 = 0x03

    public static func decodeSessionSetup(_ frame: PebbleProtocolFrame) throws -> VoiceSessionSetupRequest {
        guard frame.endpoint == endpoint else {
            throw VoiceCodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 9, frame.payload[0] == 0x01 else {
            throw VoiceCodecError.invalidPayload
        }
        guard let sessionType = VoiceSessionType(rawValue: frame.payload[5]) else {
            throw VoiceCodecError.invalidPayload
        }
        let sessionID = UInt16(frame.payload[6]) | UInt16(frame.payload[7]) << 8
        let attributeCount = Int(frame.payload[8])

        var applicationID: UUID?
        var encoderInfo: SpeexEncoderInfo?
        var offset = 9
        for _ in 0..<attributeCount {
            guard frame.payload.count >= offset + 3 else {
                throw VoiceCodecError.invalidPayload
            }
            let attributeID = frame.payload[offset]
            let length = Int(frame.payload[offset + 1]) | Int(frame.payload[offset + 2]) << 8
            offset += 3
            guard frame.payload.count >= offset + length else {
                throw VoiceCodecError.invalidPayload
            }
            let content = Array(frame.payload[offset..<offset + length])
            offset += length

            switch attributeID {
            case speexEncoderInfoAttribute:
                encoderInfo = try decodeSpeexEncoderInfo(content)
            case applicationIDAttribute where length == 16:
                applicationID = uuid(from: content)
            default:
                continue
            }
        }
        return VoiceSessionSetupRequest(
            sessionType: sessionType,
            sessionID: sessionID,
            applicationID: applicationID,
            encoderInfo: encoderInfo
        )
    }

    public static func sessionSetupResultFrame(
        sessionType: VoiceSessionType,
        result: VoiceSessionResult,
        applicationInitiated: Bool
    ) -> PebbleProtocolFrame {
        var payload: [UInt8] = [0x01]
        payload.append(contentsOf: flags(applicationInitiated: applicationInitiated))
        payload.append(sessionType.rawValue)
        payload.append(result.rawValue)
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    public static func dictationResultFrame(
        sessionID: UInt16,
        result: VoiceSessionResult,
        words: [VoiceTranscriptionWord]?,
        applicationID: UUID?
    ) -> PebbleProtocolFrame {
        var payload: [UInt8] = [0x02]
        payload.append(contentsOf: flags(applicationInitiated: applicationID != nil))
        payload.append(UInt8(sessionID & 0xFF))
        payload.append(UInt8(sessionID >> 8))
        payload.append(result.rawValue)

        var attributes: [[UInt8]] = []
        if let words {
            attributes.append(attribute(id: transcriptionAttribute, content: transcription(words)))
        }
        if let applicationID {
            attributes.append(attribute(id: applicationIDAttribute, content: BlobDBCodec.uuidBytes(applicationID)))
        }
        payload.append(UInt8(attributes.count))
        for attribute in attributes {
            payload.append(contentsOf: attribute)
        }
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    private static func flags(applicationInitiated: Bool) -> [UInt8] {
        UInt32(applicationInitiated ? 1 : 0).littleEndianBytes
    }

    private static func attribute(id: UInt8, content: [UInt8]) -> [UInt8] {
        [id, UInt8(content.count & 0xFF), UInt8(content.count >> 8)] + content
    }

    private static func transcription(_ words: [VoiceTranscriptionWord]) -> [UInt8] {
        // Transcription type 0x01: a single sentence containing every word.
        var content: [UInt8] = [0x01, 0x01]
        content.append(UInt8(words.count & 0xFF))
        content.append(UInt8(words.count >> 8))
        for word in words {
            let bytes = Array(word.text.utf8.prefix(Int(UInt16.max)))
            content.append(UInt8((max(0, min(1, word.confidence)) * 255).rounded()))
            content.append(UInt8(bytes.count & 0xFF))
            content.append(UInt8(bytes.count >> 8))
            content.append(contentsOf: bytes)
        }
        return content
    }

    private static func decodeSpeexEncoderInfo(_ content: [UInt8]) throws -> SpeexEncoderInfo {
        guard content.count >= 29 else {
            throw VoiceCodecError.invalidPayload
        }
        let version = String(decoding: content[0..<20].prefix { $0 != 0 }, as: UTF8.self)
        let sampleRate = UInt32(content[20])
            | UInt32(content[21]) << 8
            | UInt32(content[22]) << 16
            | UInt32(content[23]) << 24
        let bitRate = UInt16(content[24]) | UInt16(content[25]) << 8
        let frameSize = UInt16(content[27]) | UInt16(content[28]) << 8
        return SpeexEncoderInfo(
            version: version,
            sampleRate: sampleRate,
            bitRate: bitRate,
            bitstreamVersion: content[26],
            frameSize: frameSize
        )
    }

    private static func uuid(from bytes: [UInt8]) -> UUID {
        UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public enum AudioStreamMessage: Equatable, Sendable {
    /// One blob per packet: every encoded frame carries a 1-byte quality header
    /// and the watch concatenates them after the frame count byte.
    case data(sessionID: UInt16, bytes: [UInt8])
    case stop(sessionID: UInt16)
}

public enum AudioStreamCodec {
    public static var endpoint: UInt16 { 10_000 }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> AudioStreamMessage {
        guard frame.endpoint == endpoint else {
            throw VoiceCodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 3 else {
            throw VoiceCodecError.invalidPayload
        }
        let sessionID = UInt16(frame.payload[1]) | UInt16(frame.payload[2]) << 8
        switch frame.payload[0] {
        case 0x02:
            guard frame.payload.count >= 4 else {
                throw VoiceCodecError.invalidPayload
            }
            return .data(sessionID: sessionID, bytes: Array(frame.payload.dropFirst(4)))
        case 0x03:
            return .stop(sessionID: sessionID)
        default:
            throw VoiceCodecError.unknownCommand
        }
    }

    public static func stopFrame(sessionID: UInt16) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [0x03, UInt8(sessionID & 0xFF), UInt8(sessionID >> 8)]
        )
    }
}

public enum VoiceCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unknownCommand
}

public enum VoiceTranscriptionOutcome: Equatable, Sendable {
    case transcribed([VoiceTranscriptionWord])
    case failed(VoiceSessionResult)
}

public protocol PebbleVoiceTranscriptionProvider: Sendable {
    func canServeSession() async -> Bool
    func transcribe(encoderInfo: SpeexEncoderInfo, audioFrames: [[UInt8]]) async -> VoiceTranscriptionOutcome
}

/// Handles the watch's dictation sessions: accepts or rejects the setup,
/// collects Speex audio until the stream stops, and reports the transcription
/// (or a protocol-level error) back to the watch.
@MainActor
public final class VoiceSessionCoordinator {
    private struct ActiveSession {
        var request: VoiceSessionSetupRequest
        var audioFrames: [[UInt8]] = []
    }

    private let send: (PebbleProtocolFrame) async throws -> Void
    private let provider: (any PebbleVoiceTranscriptionProvider)?
    private var activeSession: ActiveSession?
    private var transcriptionTask: Task<Void, Never>?

    public init(
        provider: (any PebbleVoiceTranscriptionProvider)?,
        send: @escaping (PebbleProtocolFrame) async throws -> Void
    ) {
        self.provider = provider
        self.send = send
    }

    public func reset() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeSession = nil
    }

    public func handleVoiceFrame(_ frame: PebbleProtocolFrame) async {
        guard let request = try? VoiceControlCodec.decodeSessionSetup(frame) else {
            return
        }
        // A new setup supersedes any session still in flight.
        reset()
        let applicationInitiated = request.applicationID != nil

        guard request.encoderInfo != nil else {
            await respondToSetup(request, result: .invalidMessage, applicationInitiated: applicationInitiated)
            return
        }
        guard let provider, await provider.canServeSession() else {
            await respondToSetup(request, result: .disabled, applicationInitiated: applicationInitiated)
            return
        }
        await respondToSetup(request, result: .success, applicationInitiated: applicationInitiated)
        activeSession = ActiveSession(request: request)
    }

    public func handleAudioFrame(_ frame: PebbleProtocolFrame) async {
        guard let message = try? AudioStreamCodec.decode(frame),
              var session = activeSession else {
            return
        }
        switch message {
        case .data(let sessionID, let bytes):
            guard sessionID == session.request.sessionID else { return }
            session.audioFrames.append(bytes)
            activeSession = session
        case .stop(let sessionID):
            guard sessionID == session.request.sessionID else { return }
            activeSession = nil
            finishSession(session)
        }
    }

    private func finishSession(_ session: ActiveSession) {
        guard let provider, let encoderInfo = session.request.encoderInfo else {
            return
        }
        transcriptionTask = Task { [send] in
            let outcome = await provider.transcribe(
                encoderInfo: encoderInfo,
                audioFrames: session.audioFrames
            )
            guard !Task.isCancelled else { return }
            let frame: PebbleProtocolFrame
            switch outcome {
            case .transcribed(let words):
                frame = VoiceControlCodec.dictationResultFrame(
                    sessionID: session.request.sessionID,
                    result: .success,
                    words: words,
                    applicationID: session.request.applicationID
                )
            case .failed(let result):
                frame = VoiceControlCodec.dictationResultFrame(
                    sessionID: session.request.sessionID,
                    result: result,
                    words: nil,
                    applicationID: session.request.applicationID
                )
            }
            try? await send(frame)
        }
    }

    private func respondToSetup(
        _ request: VoiceSessionSetupRequest,
        result: VoiceSessionResult,
        applicationInitiated: Bool
    ) async {
        try? await send(VoiceControlCodec.sessionSetupResultFrame(
            sessionType: request.sessionType,
            result: result,
            applicationInitiated: applicationInitiated
        ))
    }
}
