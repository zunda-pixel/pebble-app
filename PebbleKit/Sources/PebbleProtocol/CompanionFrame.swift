/// An endpoint the transport carries for the app rather than answering itself.
///
/// Most of what the watch sends is answered inside the transport, which knows
/// the request it belongs to. These five are not: they are for something only
/// the app has — the phone's music, its calls, its speech recognizer, its own
/// copy of the watch's databases — so the transport passes the frame to
/// `frames()` and the app answers from there.
///
/// Listing them once is what keeps the transport from reporting them as
/// unanswered, which they are not. The app switches over this too, so a case
/// added here is a case the app cannot forget; a new endpoint the app handles
/// and does not add here is only mis-logged, and the log says so.
public enum CompanionFrame: Sendable, CaseIterable {
    case musicControl
    case phoneControl
    case voiceControl
    case audioStream
    case watchDatabaseWrite

    public var endpoint: UInt16 {
        switch self {
        case .musicControl: MusicControlCodec.endpoint
        case .phoneControl: PhoneControlCodec.endpoint
        case .voiceControl: VoiceControlCodec.endpoint
        case .audioStream: AudioStreamCodec.endpoint
        case .watchDatabaseWrite: BlobDB2Codec.endpoint
        }
    }

    public init?(endpoint: UInt16) {
        guard let match = Self.allCases.first(where: { $0.endpoint == endpoint }) else {
            return nil
        }
        self = match
    }
}
