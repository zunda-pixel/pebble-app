import Defaults
import Foundation
import Testing
@testable import PebbleApp

/// Which language dictation listens for: the reader's choice, or the phone's
/// own where they chose to follow it.
@Suite
struct VoiceLanguageTests {
    @Test func nobodyHasChosenSoThePhoneSpeaks() {
        let phone = Locale(identifier: "ja_JP")

        #expect(SpeechBridge.wantedLocale(chosenIdentifier: nil, phone: phone) == phone)
    }

    @Test func aChoiceOutranksThePhone() {
        let wanted = SpeechBridge.wantedLocale(
            chosenIdentifier: "en_US",
            phone: Locale(identifier: "ja_JP")
        )

        #expect(wanted == Locale(identifier: "en_US"))
    }

    /// Following the phone is where everyone starts, not a choice they made.
    @Test func theDefaultIsToFollowThePhone() {
        #expect(Defaults.Keys.voiceSpokenLanguage.defaultValue == nil)
    }
}
