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

    /// Half past seven in the evening, so that "five" is behind us and "nine"
    /// is still ahead.
    private static func evening() throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 2, hour: 19, minute: 30
        )))
    }

    private static func clock(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
    }

    @Test func theHourTheModelReadIsTurnedIntoADateByTheCalendar() throws {
        // What no rule could read out of "wake me at five", and what the date
        // detector reads as tomorrow at noon in "tomorrow at five".
        let now = try Self.evening()

        let tonight = ReminderReading.time(
            from: UnderstoodReminder(title: "call the dentist", hour: 21, minute: 15),
            in: "call the dentist at 9:15 tonight",
            now: now
        )
        #expect(Self.clock(try #require(tonight)) == DateComponents(month: 9, day: 2, hour: 21, minute: 15))

        // Five has gone for today, so the next five is what was meant.
        let morning = ReminderReading.time(
            from: UnderstoodReminder(title: "wake me", hour: 5),
            in: "wake me at five",
            now: now
        )
        #expect(Self.clock(try #require(morning)) == DateComponents(month: 9, day: 3, hour: 5, minute: 0))

        // A day the model counted out stands, even where the hour has passed.
        let tomorrow = ReminderReading.time(
            from: UnderstoodReminder(title: "buy milk", hour: 9, daysFromToday: 1),
            in: "buy milk at nine tomorrow",
            now: now
        )
        #expect(Self.clock(try #require(tomorrow)) == DateComponents(month: 9, day: 3, hour: 9, minute: 0))
    }

    @Test func aClockReadingTheModelCouldNotGiveLeavesTheTimeToTheDetector() throws {
        let now = try Self.evening()
        // No hour means the sentence named no time, which is an answer.
        #expect(ReminderReading.time(
            from: UnderstoodReminder(title: "buy milk"),
            in: "buy some milk",
            now: now
        ) == nil)
        // The rest are a model that has lost its place, not a reminder.
        for lost in [
            UnderstoodReminder(title: "x", hour: 24),
            UnderstoodReminder(title: "x", hour: -1),
            UnderstoodReminder(title: "x", hour: 9, minute: 60),
            UnderstoodReminder(title: "x", hour: 9, daysFromToday: 32),
        ] {
            #expect(ReminderReading.time(from: lost, in: "x at nine", now: now) == nil)
        }
    }

    @Test func anHourNobodySaidIsNotTakenFromTheModel() throws {
        let now = try Self.evening()
        // Both measured on 2026-09-02: midnight for "wake me at five", eleven
        // o'clock for "in 20 minutes". Neither number is in the sentence.
        #expect(ReminderReading.time(
            from: UnderstoodReminder(title: "wake me", hour: 0),
            in: "wake me at five",
            now: now
        ) == nil)
        #expect(ReminderReading.time(
            from: UnderstoodReminder(title: "take the bins out", hour: 11),
            in: "in 20 minutes take the bins out",
            now: now
        ) == nil)
    }

    @Test func anHourSpokenAsOneOfTwelveIsTheSameHour() {
        // Seven in the evening is nineteen, and both are the seven that was
        // said. Numbers reach this in digits or in words.
        #expect(ReminderReading.numbersNamed(in: "call mum at 7") == [7])
        #expect(ReminderReading.numbersNamed(in: "wake me at five") == [5])
        #expect(ReminderReading.numbersNamed(in: "in 20 minutes") == [20])
        #expect(ReminderReading.numbersNamed(in: "buy some milk").isEmpty)
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
