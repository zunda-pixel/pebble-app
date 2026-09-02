import Foundation
import Testing
import PebbleAudio
import PebbleProtocol
import libspeex

@Suite struct SpeexAudioTests {
    /// What the watch says about its own encoder: `voice_speex.c` fills this in
    /// from the encoder it has just set up.
    static let watchEncoderInfo = SpeexEncoderInfo(
        version: "1.2.1",
        sampleRate: 16_000,
        bitRate: 9_800,
        bitstreamVersion: 4,
        frameSize: 320
    )

    @Test func aSessionTheWatchRecordedComesBackAsTheSameSound() throws {
        let tone = 300.0
        let spoken = pulseTrain(hertz: tone, frames: 12)
        let encoded = WatchStyleSpeexEncoder().encode(spoken)
        let decoder = try SpeexAudioDecoder(encoderInfo: Self.watchEncoderInfo)
        #expect(decoder.samplesPerFrame == 320)

        var heard: [Int16] = []
        for frame in encoded {
            heard.append(contentsOf: try decoder.decode(frame))
        }

        #expect(heard.count == spoken.count)
        // The codec needs a few frames to settle, so the tail is what is
        // compared: it should still be the same note, at about the same volume.
        let tail = Array(heard.suffix(320 * 6))
        let original = Array(spoken.suffix(320 * 6))
        #expect(rootMeanSquare(tail) > rootMeanSquare(original) / 4)
        #expect(rootMeanSquare(tail) < rootMeanSquare(original) * 4)
        let atTheNote = energy(tail, hertz: tone)
        let wellAboveIt = energy(tail, hertz: 3_000)
        #expect(atTheNote > wellAboveIt * 10)
    }

    @Test func eachFrameHoldsOneFramesWorthOfSamples() throws {
        let encoded = WatchStyleSpeexEncoder().encode(pulseTrain(hertz: 300, frames: 3))
        #expect(encoded.count == 3)
        // The watch sends every frame as its own audio message, and its length
        // byte is a byte: a frame that did not fit could not be sent.
        #expect(encoded.allSatisfy { !$0.isEmpty && $0.count <= 255 })
        let decoder = try SpeexAudioDecoder(encoderInfo: Self.watchEncoderInfo)
        for frame in encoded {
            #expect(try decoder.decode(frame).count == 320)
        }
    }

    @Test func aFormatThisAppCannotDecodeIsRefusedRatherThanGuessedAt() {
        var newerBitstream = Self.watchEncoderInfo
        newerBitstream.bitstreamVersion = 5
        #expect(throws: SpeexAudioDecoder.Failure.unsupportedBitstreamVersion(5)) {
            try SpeexAudioDecoder(encoderInfo: newerBitstream)
        }

        var unheardRate = Self.watchEncoderInfo
        unheardRate.sampleRate = 44_100
        #expect(throws: SpeexAudioDecoder.Failure.unsupportedSampleRate(44_100)) {
            try SpeexAudioDecoder(encoderInfo: unheardRate)
        }

        var mismatchedFrame = Self.watchEncoderInfo
        mismatchedFrame.frameSize = 160
        #expect(throws: SpeexAudioDecoder.Failure.unexpectedFrameSize(watch: 160, mode: 320)) {
            try SpeexAudioDecoder(encoderInfo: mismatchedFrame)
        }
    }

    @Test func aFrameWithNothingInItIsRefused() throws {
        let decoder = try SpeexAudioDecoder(encoderInfo: Self.watchEncoderInfo)
        #expect(throws: SpeexAudioDecoder.Failure.frameRefused) {
            try decoder.decode([])
        }
    }

    /// A note with harmonics rather than a pure sine: what a voice codec is
    /// built to carry, and what a pure tone is not.
    private func pulseTrain(hertz: Double, frames: Int) -> [Int16] {
        (0..<(frames * 320)).map { index in
            let phase = 2 * Double.pi * hertz * Double(index) / 16_000
            let wave = sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)
            return Int16(wave * 8_000)
        }
    }

    private func rootMeanSquare(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0.0) { $0 + pow(Double($1) / 32_768, 2) }
        return (total / Double(samples.count)).squareRoot()
    }

    /// How much of the signal sits at one frequency, by Goertzel's filter.
    private func energy(_ samples: [Int16], hertz: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * hertz / 16_000)
        var previous = 0.0
        var beforeThat = 0.0
        for sample in samples {
            let current = Double(sample) / 32_768 + coefficient * previous - beforeThat
            beforeThat = previous
            previous = current
        }
        return previous * previous + beforeThat * beforeThat - coefficient * previous * beforeThat
    }
}

/// libspeex set up the way `voice_speex.c` sets it up, so a test can produce
/// the frames a watch would have sent without a watch in the room.
@safe
private final class WatchStyleSpeexEncoder {
    private let state: UnsafeMutableRawPointer
    private var bits = unsafe SpeexBits()

    init() {
        let mode = unsafe speex_lib_get_mode(SPEEX_MODEID_WB)
        unsafe state = speex_encoder_init(mode)
        unsafe speex_bits_init(&bits)
        for (request, value) in [
            (SPEEX_SET_QUALITY, Int32(6)),
            (SPEEX_SET_COMPLEXITY, Int32(1)),
            (SPEEX_SET_SAMPLING_RATE, Int32(16_000)),
            (SPEEX_SET_BITRATE, Int32(9_800)),
        ] {
            var value = value
            unsafe speex_encoder_ctl(state, request, &value)
        }
    }

    deinit {
        unsafe speex_bits_destroy(&bits)
        unsafe speex_encoder_destroy(state)
    }

    func encode(_ samples: [Int16]) -> [[UInt8]] {
        stride(from: 0, to: samples.count, by: 320).compactMap { start in
            guard start + 320 <= samples.count else { return nil }
            var frame = Array(samples[start..<start + 320])
            unsafe speex_bits_reset(&bits)
            _ = frame.withUnsafeMutableBufferPointer { input in
                unsafe speex_encode_int(state, input.baseAddress, &bits)
            }
            var encoded = [CChar](repeating: 0, count: 320)
            let count = encoded.withUnsafeMutableBufferPointer { output in
                unsafe speex_bits_write(&bits, output.baseAddress, 320)
            }
            return encoded.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        }
    }
}
