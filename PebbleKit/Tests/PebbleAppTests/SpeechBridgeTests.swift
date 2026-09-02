import Foundation
import Testing
@testable import PebbleApp
import PebbleProtocol

@Suite struct SpeechBridgeTests {
    @Test func aTranscriptIsCutWhereTheWatchExpectsCuts() {
        let words = SpeechBridge.words(in: AttributedString("Buy some milk"))
        #expect(words.map(\.text) == ["Buy", "some", "milk"])
    }

    @Test func aLanguageWrittenWithoutSpacesArrivesAsOneWord() {
        // The watch puts a space between every word it is sent, so a Japanese
        // sentence handed over word by word would come back with gaps in it.
        let words = SpeechBridge.words(in: AttributedString("牛乳を買う"))
        #expect(words.map(\.text) == ["牛乳を買う"])
    }

    @Test func aRecognizerWithNoConfidenceToGiveSaysSoRatherThanGuessing() {
        let words = SpeechBridge.words(in: AttributedString("milk"))
        #expect(words.map(\.confidence) == [0])
    }

    @Test func aRemindersSessionIsRefusedWhileTheAppCannotReadOne() async {
        // Transcribing is not the same as understanding: the Reminders app wants
        // a reminder and a time, and words it cannot use are worse than a no.
        let bridge = SpeechBridge()
        #expect(await bridge.canServeSession(.naturalLanguage) == false)
    }
}
