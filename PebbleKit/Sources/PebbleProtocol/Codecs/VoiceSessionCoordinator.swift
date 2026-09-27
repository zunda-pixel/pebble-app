import Foundation

public enum VoiceTranscriptionOutcome: Equatable, Sendable {
    case transcribed([VoiceTranscriptionWord])
    case failed(VoiceSessionResult)
}

public protocol VoiceTranscriptionProvider: Sendable {
    /// Whether this kind of session can be served at all. A phone that can turn
    /// speech into words may still have no way to read a reminder out of them.
    func canServeSession(_ sessionType: VoiceSessionType) async -> Bool
    func transcribe(encoderInfo: SpeexEncoderInfo, audioFrames: [[UInt8]]) async -> VoiceTranscriptionOutcome
    func interpretReminder(_ words: [VoiceTranscriptionWord]) async -> VoiceReminderOutcome
}

extension VoiceTranscriptionProvider {
    public func interpretReminder(_ words: [VoiceTranscriptionWord]) async -> VoiceReminderOutcome {
        .failed(.serviceUnavailable)
    }
}

@MainActor
public final class VoiceSessionCoordinator {
    private struct ActiveSession {
        var request: VoiceSessionSetupRequest
        var audioFrames: [[UInt8]] = []
    }

    private let send: (PebbleProtocolFrame) async throws -> Void
    private let provider: (any VoiceTranscriptionProvider)?
    private var activeSession: ActiveSession?
    private var transcriptionTask: Task<Void, Never>?

    public init(
        provider: (any VoiceTranscriptionProvider)?,
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
            // Saying nothing leaves the watch waiting out its own timeout, and it
            // asks twice more before telling the reader that dictation is not
            // available — three quiet failures where one honest one would do.
            try? await send(VoiceControlCodec.sessionSetupResultFrame(
                sessionTypeValue: frame.payload.count > 5 ? frame.payload[5] : 0,
                result: .invalidMessage,
                applicationInitiated: false
            ))
            return
        }
        reset()
        let applicationInitiated = request.applicationID != nil

        guard request.encoderInfo != nil else {
            await respondToSetup(request, result: .invalidMessage, applicationInitiated: applicationInitiated)
            return
        }
        guard let provider, await provider.canServeSession(request.sessionType) else {
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
        case .data(let sessionID, let frames):
            guard sessionID == session.request.sessionID else { return }
            session.audioFrames.append(contentsOf: frames)
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
        let request = session.request
        transcriptionTask = Task { [send] in
            let outcome = await provider.transcribe(
                encoderInfo: encoderInfo,
                audioFrames: session.audioFrames
            )
            guard !Task.isCancelled else { return }
            let frame = switch request.sessionType {
            case .naturalLanguage:
                await Self.reminderFrame(for: outcome, request: request, provider: provider)
            case .dictation, .command:
                Self.dictationFrame(for: outcome, request: request)
            }
            guard !Task.isCancelled else { return }
            try? await send(frame)
        }
    }

    private static func dictationFrame(
        for outcome: VoiceTranscriptionOutcome,
        request: VoiceSessionSetupRequest
    ) -> PebbleProtocolFrame {
        switch outcome {
        case .transcribed(let words):
            VoiceControlCodec.dictationResultFrame(
                sessionID: request.sessionID,
                result: .success,
                words: words,
                applicationID: request.applicationID
            )
        case .failed(let result):
            VoiceControlCodec.dictationResultFrame(
                sessionID: request.sessionID,
                result: result,
                words: nil,
                applicationID: request.applicationID
            )
        }
    }

    private static func reminderFrame(
        for outcome: VoiceTranscriptionOutcome,
        request: VoiceSessionSetupRequest,
        provider: any VoiceTranscriptionProvider
    ) async -> PebbleProtocolFrame {
        let interpretation: VoiceReminderOutcome = switch outcome {
        case .transcribed(let words): await provider.interpretReminder(words)
        case .failed(let result): .failed(result)
        }
        switch interpretation {
        case .understood(let reminder, let time):
            return VoiceControlCodec.nlpResultFrame(
                sessionID: request.sessionID,
                result: .success,
                reminder: reminder,
                time: time
            )
        case .failed(let result):
            return VoiceControlCodec.nlpResultFrame(
                sessionID: request.sessionID,
                result: result,
                reminder: nil,
                time: nil
            )
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
