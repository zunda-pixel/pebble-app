public import PebbleProtocol
import AVFoundation
import Defaults
import Foundation
import PebbleAudio
import Speech

/// What the phone can do about the watch's microphone right now.
public enum VoiceTranscriptionReadiness: Equatable, Sendable {
    /// No recognizer on this phone speaks the language it is set to.
    case unsupported
    /// The reader has turned dictation off.
    case turnedOff
    /// The recognizer needs its model before it can hear anything.
    case needsInstalling
    case installing
    case ready
}

enum SpeechBridgeFailure: Error, Equatable, Sendable {
    /// No format both the recognizer and this app can hold the sound in.
    case noFormatInCommon
}

/// Turns what the watch heard into words, using the phone's own recognizer.
///
/// The watch records Speex and streams it while the reader is still speaking,
/// but it wants one answer at the end, so the frames are decoded and analysed
/// in one go here. Everything stays on the phone: `SpeechAnalyzer` sends no
/// audio to a server.
actor SpeechBridge: PebbleVoiceTranscriptionProvider {
    private var installation: Task<Void, any Error>?
    private var hasInstalledAssets = false

    /// The recognizer for the language the phone is set to, if there is one.
    private nonisolated func supportedLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    }

    func readiness() async -> VoiceTranscriptionReadiness {
        guard let locale = await supportedLocale() else { return .unsupported }
        guard Defaults[.voiceTranscriptionEnabled] else { return .turnedOff }
        if hasInstalledAssets { return .ready }
        if installation != nil { return .installing }
        return await assetRequest(for: locale) == nil ? .ready : .needsInstalling
    }

    /// Fetches the recognizer's model, if it is not already on the phone.
    ///
    /// Worth doing when the reader turns dictation on rather than when the watch
    /// first asks: the download outlasts the watch's patience by far.
    func installAssets() async throws {
        if let installation {
            return try await installation.value
        }
        guard let locale = await supportedLocale() else { return }
        let installation = Task<Void, any Error> {
            if let request = await assetRequest(for: locale) {
                try await request.downloadAndInstall()
            }
        }
        self.installation = installation
        defer { self.installation = nil }
        try await installation.value
        hasInstalledAssets = true
    }

    private func assetRequest(for locale: Locale) async -> AssetInstallationRequest? {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        return try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
    }

    func canServeSession(_ sessionType: VoiceSessionType) async -> Bool {
        await readiness() == .ready
    }

    func interpretReminder(_ words: [VoiceTranscriptionWord]) async -> VoiceReminderOutcome {
        let spoken = words.map(\.text).joined(separator: " ")
        guard !spoken.isEmpty else { return .failed(.recognizerError) }
        let reminder = await ReminderReading.readWithModel(spoken)
        guard !reminder.text.isEmpty else { return .failed(.recognizerError) }
        return .understood(reminder: reminder.text, time: reminder.time)
    }

    func transcribe(
        encoderInfo: SpeexEncoderInfo,
        audioFrames: [[UInt8]]
    ) async -> VoiceTranscriptionOutcome {
        guard let locale = await supportedLocale() else { return .failed(.serviceUnavailable) }
        let samples: [Int16]
        do {
            samples = try decode(audioFrames, encoderInfo: encoderInfo)
        } catch {
            await PebbleDiagnostics.shared.record(
                category: "voice",
                message: "Could not decode the watch's audio: \(error)"
            )
            return .failed(.recognizerError)
        }
        guard !samples.isEmpty else { return .failed(.recognizerError) }

        do {
            let spoken = try await transcribe(samples, sampleRate: Double(encoderInfo.sampleRate), in: locale)
            let words = Self.words(in: spoken)
            // What was said is nobody's business but the reader's, and the
            // report is made to be shared: how much was heard, and how much
            // came back, is all that helps.
            await PebbleDiagnostics.shared.record(
                category: "voice",
                message: "heard \(audioFrames.count) frames"
                    + ", \(samples.count / max(1, Int(encoderInfo.sampleRate))) s"
                    + ", \(words.count) words back"
            )
            guard !words.isEmpty else { return .failed(.recognizerError) }
            return .transcribed(words)
        } catch {
            await PebbleDiagnostics.shared.record(
                category: "voice",
                message: "The recognizer gave up: \(error)"
            )
            return .failed(.recognizerError)
        }
    }

    private func decode(
        _ audioFrames: [[UInt8]],
        encoderInfo: SpeexEncoderInfo
    ) throws -> [Int16] {
        let decoder = try SpeexAudioDecoder(encoderInfo: encoderInfo)
        var samples: [Int16] = []
        samples.reserveCapacity(audioFrames.count * decoder.samplesPerFrame)
        for frame in audioFrames {
            // A frame the watch dropped or garbled is a gap in the sound, not a
            // reason to throw away everything that was said around it.
            guard let decoded = try? decoder.decode(frame) else { continue }
            samples.append(contentsOf: decoded)
        }
        return samples
    }

    private func transcribe(
        _ samples: [Int16],
        sampleRate: Double,
        in locale: Locale
    ) async throws -> AttributedString {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw SpeechBridgeFailure.noFormatInCommon
        }
        let converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
        let (inputs, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        for input in try converter.convert(Self.buffer(of: samples, sampleRate: sampleRate), at: nil) {
            builder.yield(input)
        }
        for input in try converter.flush() {
            builder.yield(input)
        }
        builder.finish()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let spoken = Self.everythingHeard(from: transcriber)
        let lastSample = try await analyzer.analyzeSequence(inputs)
        if let lastSample {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await spoken
    }

    /// The results in the order they were said. The preset asks for no volatile
    /// results, so each one arrives already settled.
    private static func everythingHeard(from transcriber: SpeechTranscriber) async throws -> AttributedString {
        var spoken = AttributedString()
        for try await result in transcriber.results {
            spoken += result.text
        }
        return spoken
    }

    private static func buffer(of samples: [Int16], sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = unsafe buffer.int16ChannelData![0]
        for (index, sample) in samples.enumerated() {
            unsafe channel[index] = sample
        }
        return buffer
    }

    /// The transcript cut where the watch expects cuts.
    ///
    /// The watch puts a space between the words it is sent, so a language that
    /// writes without spaces has to arrive as one word — which is what falls out
    /// of splitting on whitespace.
    static func words(in spoken: AttributedString) -> [VoiceTranscriptionWord] {
        spoken.runs.flatMap { run in
            String(spoken[run.range].characters)
                .split(whereSeparator: \.isWhitespace)
                .map { text in
                    VoiceTranscriptionWord(
                        text: String(text),
                        confidence: run.transcriptionConfidence ?? 0
                    )
                }
        }
    }
}
