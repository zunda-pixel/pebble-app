import UniformTypeIdentifiers

/// The file types the app imports, named so pickers read clearly.
///
/// The identifiers are declared in the app target's `Info.plist`
/// (`UTImportedTypeDeclarations` + `CFBundleDocumentTypes`): the declaration is
/// what puts this app in the system's open-with and share sheets for a
/// downloaded package — without it a `.pbw` from Safari had nowhere to go
/// (#103). The extension lookup remains as the fallback for a process that
/// runs without the app bundle, such as a test host.
extension UTType {
    /// A watch app or watchface package.
    static var pebblePackage: UTType {
        UTType("com.getpebble.watchapp") ?? UTType(filenameExtension: "pbw") ?? .data
    }

    /// A firmware package.
    static var pebbleFirmware: UTType {
        UTType("com.getpebble.firmware") ?? UTType(filenameExtension: "pbz") ?? .data
    }

    /// A language pack.
    static var pebbleLanguagePack: UTType {
        UTType("com.getpebble.languagepack") ?? UTType(filenameExtension: "pbl") ?? .data
    }
}
