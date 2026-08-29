import UniformTypeIdentifiers

/// The file types the app imports, named so pickers read clearly.
extension UTType {
    /// A watch app or watchface package.
    static var pebblePackage: UTType {
        UTType(filenameExtension: "pbw") ?? .data
    }

    /// A firmware package.
    static var pebbleFirmware: UTType {
        UTType(filenameExtension: "pbz") ?? .data
    }
}
