public import Foundation
import MemberwiseInit

public enum VoiceSessionType: UInt8, Equatable, Sendable {
    case dictation = 0x01
    case command = 0x02
    /// What the watch's own Reminders app asks for: the phone is expected to
    /// return a reminder and a time rather than a transcription.
    case naturalLanguage = 0x03
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
    /// 0...1, sent as the watch's 1-100 percentage. Zero reaches the watch as
    /// its "no confidence value" marker, which is what a recognizer that does
    /// not score words means.
    public var confidence: Double = 0.9
}

/// What a natural-language session asks for: the words are not wanted, a
/// reminder and the time it is for are.
public enum VoiceReminderOutcome: Equatable, Sendable {
    case understood(reminder: String, time: Date?)
    case failed(VoiceSessionResult)
}

public enum VoiceControlCodec {
    public static var endpoint: UInt16 { 11_000 }

    static let speexEncoderInfoAttribute: UInt8 = 0x01
    static let transcriptionAttribute: UInt8 = 0x02
    static let applicationIDAttribute: UInt8 = 0x03
    static let reminderAttribute: UInt8 = 0x04
    static let timestampAttribute: UInt8 = 0x05

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
        sessionSetupResultFrame(
            sessionTypeValue: sessionType.rawValue,
            result: result,
            applicationInitiated: applicationInitiated
        )
    }

    /// For answering a request this app could not read: the watch still needs
    /// the type byte back, and refusing to answer at all is worse than echoing
    /// one this app has no name for.
    public static func sessionSetupResultFrame(
        sessionTypeValue: UInt8,
        result: VoiceSessionResult,
        applicationInitiated: Bool
    ) -> PebbleProtocolFrame {
        var payload: [UInt8] = [0x01]
        payload.append(contentsOf: flags(applicationInitiated: applicationInitiated))
        payload.append(sessionTypeValue)
        payload.append(result.rawValue)
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    public static func dictationResultFrame(
        sessionID: UInt16,
        result: VoiceSessionResult,
        words: [VoiceTranscriptionWord]?,
        applicationID: UUID?
    ) -> PebbleProtocolFrame {
        let sentence = words.map(sendableWords) ?? []
        var attributes: [[UInt8]] = []
        if !sentence.isEmpty {
            attributes.append(attribute(id: transcriptionAttribute, content: transcription(sentence)))
        }
        if let applicationID {
            attributes.append(attribute(id: applicationIDAttribute, content: BlobDBCodec.uuidBytes(applicationID)))
        }
        // A success with no words is one the watch throws out for being
        // malformed, and it then tells the reader the recognizer misbehaved.
        // Saying that outright is the same news, one step sooner.
        let honestResult = words != nil && sentence.isEmpty ? .recognizerError : result
        return resultFrame(
            messageID: 0x02,
            sessionID: sessionID,
            result: honestResult,
            applicationInitiated: applicationID != nil,
            attributes: attributes
        )
    }

    /// The answer to a natural-language session: what to remind the reader of,
    /// and when. The watch ignores an application ID here, and a session it
    /// started itself is never application-initiated.
    public static func nlpResultFrame(
        sessionID: UInt16,
        result: VoiceSessionResult,
        reminder: String?,
        time: Date?
    ) -> PebbleProtocolFrame {
        let text = reminder.map(wireBytes) ?? []
        var attributes: [[UInt8]] = []
        if !text.isEmpty {
            attributes.append(attribute(id: reminderAttribute, content: text))
            if let time, let seconds = watchSeconds(time) {
                attributes.append(attribute(id: timestampAttribute, content: seconds.littleEndianBytes))
            }
        }
        return resultFrame(
            messageID: 0x03,
            sessionID: sessionID,
            result: text.isEmpty && result == .success ? .recognizerError : result,
            applicationInitiated: false,
            attributes: attributes
        )
    }

    private static func resultFrame(
        messageID: UInt8,
        sessionID: UInt16,
        result: VoiceSessionResult,
        applicationInitiated: Bool,
        attributes: [[UInt8]]
    ) -> PebbleProtocolFrame {
        var payload: [UInt8] = [messageID]
        payload.append(contentsOf: flags(applicationInitiated: applicationInitiated))
        payload.append(UInt8(sessionID & 0xFF))
        payload.append(UInt8(sessionID >> 8))
        payload.append(result.rawValue)
        payload.append(UInt8(attributes.count))
        for attribute in attributes {
            payload.append(contentsOf: attribute)
        }
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    private static func watchSeconds(_ time: Date) -> UInt32? {
        let seconds = time.timeIntervalSince1970.rounded()
        guard seconds >= 0, seconds <= Double(UInt32.max) else { return nil }
        return UInt32(seconds)
    }

    private static func flags(applicationInitiated: Bool) -> [UInt8] {
        UInt32(applicationInitiated ? 1 : 0).littleEndianBytes
    }

    private static func attribute(id: UInt8, content: [UInt8]) -> [UInt8] {
        [id, UInt8(content.count & 0xFF), UInt8(content.count >> 8)] + content
    }

    /// The words the watch will accept, in the order they were said. A word of
    /// no length fails the watch's check on the whole transcription, so an empty
    /// one is dropped rather than sent.
    private static func sendableWords(
        _ words: [VoiceTranscriptionWord]
    ) -> [(bytes: [UInt8], confidence: UInt8)] {
        words.compactMap { word in
            let bytes = wireBytes(word.text)
            guard !bytes.isEmpty else { return nil }
            return (bytes, UInt8((max(0, min(1, word.confidence)) * 100).rounded()))
        }
    }

    private static func transcription(_ words: [(bytes: [UInt8], confidence: UInt8)]) -> [UInt8] {
        // Transcription type 0x01: a single sentence containing every word.
        var content: [UInt8] = [0x01, 0x01]
        content.append(UInt8(words.count & 0xFF))
        content.append(UInt8(words.count >> 8))
        for word in words {
            content.append(word.confidence)
            content.append(UInt8(word.bytes.count & 0xFF))
            content.append(UInt8(word.bytes.count >> 8))
            content.append(contentsOf: word.bytes)
        }
        return content
    }

    /// UTF-8 the watch will take: one control character anywhere in a
    /// transcription makes it throw the lot away, and a recognizer that hands
    /// back a line break has not earned that.
    private static func wireBytes(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            guard bytes.count + encoded.count <= Int(UInt16.max) else { break }
            if encoded.count == 1, encoded[0] < 0x20, encoded[0] != 0x08 {
                bytes.append(0x20)
            } else {
                bytes.append(contentsOf: encoded)
            }
        }
        return bytes
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

public enum VoiceCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unknownCommand
}
