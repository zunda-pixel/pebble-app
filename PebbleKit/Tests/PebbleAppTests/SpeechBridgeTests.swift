import Foundation
import Speech
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
        // The recognizer hands it over exactly that way: asking for confidence
        // puts every segment in its own run, and the watch wrote 「は い 。」.
        let spoken = Self.asHeard(["牛乳", "を", "買う"])
        #expect(spoken.runs.count == 3)

        let words = SpeechBridge.words(in: spoken)

        #expect(words.map(\.text) == ["牛乳を買う"])
    }

    @Test func wordsTheRecognizerSeparatedStaySeparate() {
        let words = SpeechBridge.words(in: Self.asHeard(["buy ", "some ", "milk"]))
        #expect(words.map(\.text) == ["buy", "some", "milk"])
    }

    /// A transcript in the shape the recognizer returns one: a run for every
    /// word it recognized, each with its own confidence.
    private static func asHeard(_ segments: [String]) -> AttributedString {
        var spoken = AttributedString()
        for (index, segment) in segments.enumerated() {
            var run = AttributedString(segment)
            run.transcriptionConfidence = 0.5 + Double(index) / 10
            spoken += run
        }
        return spoken
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
