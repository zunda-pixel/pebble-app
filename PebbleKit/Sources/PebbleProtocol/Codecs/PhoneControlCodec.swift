/// The endpoint a phone tells the watch about calls on. This one does not
/// (#80), but the watch's frames on it are still the app's to receive.
public enum PhoneControlCodec {
    public static var endpoint: UInt16 { 33 }
}
