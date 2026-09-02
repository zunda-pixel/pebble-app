import Foundation
import Testing
@testable import PebbleApp

/// Where the screens' text is looked up.
///
/// Every SwiftUI initializer that takes a `LocalizedStringKey` searches
/// `Bundle.main`, and the screens are compiled into this package, whose strings
/// ship in a bundle of its own. The shims in `ModuleLocalization.swift` are what
/// point them at it; these check the half a test can see — that the catalogue
/// travels with this module and answers in Japanese.
@Suite
struct ModuleLocalizationTests {
    @Test
    func theCatalogueTravelsWithThisModule() throws {
        #expect(Bundle.pebbleApp.localizations.contains("ja"))
        #expect(Bundle.pebbleApp.localizations.contains("en"))
    }

    @Test
    func everyScreensStringIsThereInJapanese() throws {
        let japanese = try #require(
            Bundle.pebbleApp.url(forResource: "ja", withExtension: "lproj")
                .flatMap(Bundle.init(url:))
        )

        #expect(japanese.localizedString(forKey: "Devices", value: nil, table: nil) == "デバイス")
        #expect(japanese.localizedString(forKey: "Connected", value: nil, table: nil) == "接続済み")
        #expect(
            japanese.localizedString(forKey: "Firmware Required", value: nil, table: nil)
                == "ファームウェアが必要"
        )
    }

    /// The main bundle is where SwiftUI looks on its own, and it holds none of
    /// this: a key read from there comes back as the English it was written as,
    /// which is exactly how a Japanese iPhone showed every screen.
    @Test
    func theAppBundleDoesNotCarryTheScreensStrings() {
        #expect(Bundle.main.localizedString(forKey: "Devices", value: nil, table: nil) == "Devices")
    }
}
