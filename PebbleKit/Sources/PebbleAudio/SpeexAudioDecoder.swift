public import PebbleProtocol
import CSpeex

/// What the watch's microphone sent, turned back into samples.
///
/// One decoder serves one session. The codec carries state from each frame to
/// the next, so frames have to go in in the order they arrived; a decoder handed
/// them out of order produces sound, just not the sound that was said.
@safe
public final class SpeexAudioDecoder {
    public enum Failure: Error, Equatable, Sendable {
        /// A rate the watch has never asked for and libspeex has no mode for.
        case unsupportedSampleRate(UInt32)
        /// A bitstream this copy of libspeex cannot read.
        case unsupportedBitstreamVersion(UInt8)
        /// The watch's frames hold a different number of samples than the mode
        /// its own sample rate implies, so one of the two is not what it says.
        case unexpectedFrameSize(watch: UInt16, mode: Int)
        case decoderUnavailable
        case frameRefused
    }

    /// The bitstream libspeex 1.2.1 reads, and the one the watch says it writes
    /// (`SPEEX_BITSTREAM_VERSION` in `voice_speex.c`).
    static let readableBitstreamVersion: UInt8 = 4

    public let sampleRate: Int
    public let samplesPerFrame: Int

    private let state: UnsafeMutableRawPointer
    private var bits = unsafe SpeexBits()

    public init(encoderInfo: SpeexEncoderInfo) throws {
        guard encoderInfo.bitstreamVersion == Self.readableBitstreamVersion else {
            throw Failure.unsupportedBitstreamVersion(encoderInfo.bitstreamVersion)
        }
        let modeID: Int32 = switch encoderInfo.sampleRate {
        case 8_000: SPEEX_MODEID_NB
        case 16_000: SPEEX_MODEID_WB
        case 32_000: SPEEX_MODEID_UWB
        default: throw Failure.unsupportedSampleRate(encoderInfo.sampleRate)
        }
        guard let mode = unsafe speex_lib_get_mode(modeID),
              let state = unsafe speex_decoder_init(mode) else {
            throw Failure.decoderUnavailable
        }
        unsafe self.state = state
        sampleRate = Int(encoderInfo.sampleRate)

        unsafe speex_bits_init(&bits)
        var frameSize: Int32 = 0
        unsafe speex_decoder_ctl(state, SPEEX_GET_FRAME_SIZE, &frameSize)
        samplesPerFrame = Int(frameSize)
        // Throwing from here on hands the codec's memory to `deinit`, which the
        // runtime still runs: everything it frees is already set up.
        guard samplesPerFrame > 0 else {
            throw Failure.decoderUnavailable
        }
        guard Int(encoderInfo.frameSize) == samplesPerFrame else {
            throw Failure.unexpectedFrameSize(watch: encoderInfo.frameSize, mode: samplesPerFrame)
        }
    }

    deinit {
        unsafe speex_bits_destroy(&bits)
        unsafe speex_decoder_destroy(state)
    }

    /// The samples one encoded frame holds.
    ///
    /// A watch with two microphone channels would put its stereo image in the
    /// frame as well. libspeex skips that on its own, and speech is recognized
    /// from one channel anyway, so nothing here asks for it back.
    public func decode(_ frame: [UInt8]) throws -> [Int16] {
        guard !frame.isEmpty else { throw Failure.frameRefused }
        frame.withUnsafeBytes { encoded in
            unsafe speex_bits_read_from(
                &bits,
                encoded.baseAddress?.assumingMemoryBound(to: CChar.self),
                Int32(encoded.count)
            )
        }
        var samples = [Int16](repeating: 0, count: samplesPerFrame)
        let status = samples.withUnsafeMutableBufferPointer { output in
            unsafe speex_decode_int(state, &bits, output.baseAddress)
        }
        guard status == 0 else { throw Failure.frameRefused }
        return samples
    }
}
