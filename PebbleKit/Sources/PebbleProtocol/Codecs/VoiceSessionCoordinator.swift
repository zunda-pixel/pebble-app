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

    /// The watch gives up on a session it has asked for after 8 seconds
    /// (`TIMEOUT_SESSION_SETUP`) and on its result 15 seconds after recording
    /// stops (`TIMEOUT_SESSION_RESULT`, both in `services/voice/voice.c`).
    /// These leave two of each for the answer to cross the link. An answer
    /// that arrives after the watch's own deadline is thrown away and the
    /// reader is shown the watch's timeout instead, so waiting for the
    /// recognizer past this gains nothing and holds the next session up.
    static let setupDeadline = Duration.seconds(6)
    static let resultDeadline = Duration.seconds(13)

    private let send: (PebbleProtocolFrame) async throws -> Void
    private let provider: (any VoiceTranscriptionProvider)?
    private let clock: any Clock<Duration>
    private var activeSession: ActiveSession?
    private var transcriptionTask: Task<Void, Never>?

    public init(
        provider: (any VoiceTranscriptionProvider)?,
        clock: any Clock<Duration> = ContinuousClock(),
        send: @escaping (PebbleProtocolFrame) async throws -> Void
    ) {
        self.provider = provider
        self.clock = clock
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
        guard let provider else {
            await respondToSetup(request, result: .disabled, applicationInitiated: applicationInitiated)
            return
        }
        let sessionType = request.sessionType
        switch await answer(within: Self.setupDeadline, { await provider.canServeSession(sessionType) }) {
        case true?:
            break
        case false?:
            await respondToSetup(request, result: .disabled, applicationInitiated: applicationInitiated)
            return
        case nil:
            await respondToSetup(request, result: .timeout, applicationInitiated: applicationInitiated)
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
        let audioFrames = session.audioFrames
        transcriptionTask = Task { [send] in
            let answered = await answer(within: Self.resultDeadline) {
                let outcome = await provider.transcribe(
                    encoderInfo: encoderInfo,
                    audioFrames: audioFrames
                )
                return switch request.sessionType {
                case .naturalLanguage:
                    await Self.reminderFrame(for: outcome, request: request, provider: provider)
                case .dictation, .command:
                    Self.dictationFrame(for: outcome, request: request)
                }
            }
            guard !Task.isCancelled else { return }
            // Said outright rather than left to the watch's own timer, which
            // ends the same way for the reader but only once it runs out, and
            // leaves the phone still working on a session nobody is waiting for.
            let frame = answered ?? Self.failureFrame(.timeout, request: request)
            try? await send(frame)
        }
    }

    /// `work`'s answer, or nil if `deadline` passes first.
    ///
    /// Not a task group: a group waits for every child before it returns, so a
    /// recognizer that does not stop when cancelled would hold the answer for
    /// as long as it liked — which is the one thing the deadline is for. The
    /// work is cancelled and left to finish on its own.
    private func answer<Value: Sendable>(
        within deadline: Duration,
        _ work: @escaping @MainActor () async -> Value
    ) async -> Value? {
        let race = DeadlineRace<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.begin(continuation, work: work, deadline: deadline, clock: clock)
            }
        } onCancel: {
            Task { @MainActor in race.finish(nil) }
        }
    }

    private static func failureFrame(
        _ result: VoiceSessionResult,
        request: VoiceSessionSetupRequest
    ) -> PebbleProtocolFrame {
        switch request.sessionType {
        case .naturalLanguage:
            VoiceControlCodec.nlpResultFrame(
                sessionID: request.sessionID,
                result: result,
                reminder: nil,
                time: nil
            )
        case .dictation, .command:
            dictationFrame(for: .failed(result), request: request)
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

/// Whichever comes first of an answer and a deadline, resumed exactly once.
@MainActor
private final class DeadlineRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var isFinished = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func begin(
        _ continuation: CheckedContinuation<Value?, Never>,
        work: @escaping @MainActor () async -> Value,
        deadline: Duration,
        clock: any Clock<Duration>
    ) {
        guard !isFinished else {
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        self.work = Task {
            let value = await work()
            self.finish(value)
        }
        timer = Task {
            guard (try? await clock.sleep(for: deadline)) != nil else { return }
            self.finish(nil)
        }
    }

    func finish(_ value: Value?) {
        guard !isFinished else { return }
        isFinished = true
        work?.cancel()
        timer?.cancel()
        continuation?.resume(returning: value)
        continuation = nil
    }
}
