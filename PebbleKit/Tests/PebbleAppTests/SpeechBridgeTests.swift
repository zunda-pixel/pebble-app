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

    @Test func aTimeSpokenAloudIsTakenOutOfTheReminderAndSentBesideIt() throws {
        let reminder = ReminderReading.read("buy some milk at 9am")
        // "Buy some milk at" is not what anyone said: the word that led into the
        // time goes with it.
        #expect(reminder.text == "buy some milk")
        let time = try #require(reminder.time)
        #expect(Calendar.current.component(.hour, from: time) == 9)
    }

    @Test func aReminderWithNoTimeInItKeepsAllItsWords() {
        let reminder = ReminderReading.read("牛乳を買う")
        #expect(reminder == SpokenReminder(text: "牛乳を買う", time: nil))
    }

    @Test func aTimeThatHasAlreadyGoneMeansTheNextOneComing() throws {
        // "at one" said in the afternoon is one in the morning, which the
        // detector places earlier today: a reminder for a moment already gone
        // is one the watch would never show.
        let reminder = ReminderReading.read("call the dentist at 1am")
        let time = try #require(reminder.time)
        #expect(time > Date())
    }
}
