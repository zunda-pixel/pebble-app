import Foundation
import FoundationModels
import PebbleProtocol

/// What was heard, read as a reminder: the thing to be reminded of, and when.
struct SpokenReminder: Equatable, Sendable {
    var text: String
    var time: Date?
}

/// Turns a spoken sentence into a reminder the watch can keep.
///
/// The language model reads the sentence and says what was meant — the words
/// for the reminder, and the hour on a clock. Arithmetic is none of its
/// business: `Calendar` turns the hour into a date, and a time already past
/// becomes the next one coming.
///
/// `NSDataDetector` answers when there is no model, or when it is too slow.
/// It is exact on what it recognizes and blind on the rest — measured against
/// English on 2026-09-02, it reads "5pm", "5:00", "five o'clock" and "noon",
/// finds nothing at all in "wake me at five", "meeting at 3" or "in 20
/// minutes", and reads "tomorrow at five" as tomorrow at noon. Needing a unit
/// or a separator before a number counts as a time is not something a rule can
/// fill in without a vocabulary for every language.
enum ReminderReading {
    /// How long the model may take before the detector answers instead. The
    /// watch gives up on a session result after fifteen seconds, and
    /// transcribing has already spent some of that.
    static let modelDeadline = Duration.seconds(5)

    private enum ModelAnswer {
        case read(UnderstoodReminder)
        /// The model was asked and gave nothing back. Why is recorded where it
        /// happened.
        case nothing
        case tooSlow
    }

    static func readWithModel(_ spoken: String, now: Date = Date()) async -> SpokenReminder {
        let detected = read(spoken, now: now)
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            // Which reader answered is the first thing to know when a reminder
            // comes out as the whole sentence: the detector cuts a time and
            // nothing else.
            await PebbleDiagnostics.shared.record(
                category: "voice",
                message: "no language model on this phone (\(reason)); the date detector read the reminder alone"
            )
            return detected
        }
        let answer = await withTaskGroup(of: ModelAnswer.self) { group in
            group.addTask { await understand(spoken, now: now) }
            group.addTask {
                try? await Task.sleep(for: modelDeadline)
                return .tooSlow
            }
            let first = await group.next() ?? .nothing
            group.cancelAll()
            return first
        }
        guard case .read(let understood) = answer else {
            if case .tooSlow = answer {
                await PebbleDiagnostics.shared.record(
                    category: "voice",
                    message: "the model was still reading the reminder after \(modelDeadline);"
                        + " the date detector answered instead"
                )
            }
            return detected
        }
        let title = understood.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A model that hands the sentence back whole has read nothing out of
        // it, and the detector has at least cut the time it found: 「五時に起こ
        // して」 came back untouched where the detector had 「起こして」.
        let shortened = !title.isEmpty && title != spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shortened {
            await PebbleDiagnostics.shared.record(
                category: "voice",
                message: "the model found nothing to cut out of the reminder"
            )
        }
        return SpokenReminder(
            // Cutting the time out leaves the same loose word behind whoever
            // did the cutting: the model answered "meeting at".
            text: shortened ? tidied(title, fallingBackTo: title) : detected.text,
            // What the detector recognizes it reads exactly, and it reads the
            // clock as well: a bare hour becomes the next time the clock shows
            // it, which is how people use one. The model is asked to fill the
            // silences, not to overrule that — measured on 2026-09-02 it read
            // 「五時に起こして」 as five in the afternoon where the detector had
            // it right.
            time: detected.time ?? time(from: understood, in: spoken, now: now)
        )
    }

    /// What `NSDataDetector` makes of the sentence, and nothing else.
    static func read(_ spoken: String, now: Date = Date()) -> SpokenReminder {
        let sentence = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else {
            return SpokenReminder(text: sentence, time: nil)
        }
        let whole = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
        guard let match = detector.firstMatch(in: sentence, range: whole),
              let date = match.date,
              let spokenTime = Range(match.range, in: sentence) else {
            return SpokenReminder(text: sentence, time: nil)
        }
        var withoutTheTime = sentence
        withoutTheTime.removeSubrange(spokenTime)
        return SpokenReminder(
            text: tidied(withoutTheTime, fallingBackTo: sentence),
            // A time with no date in it lands on the day the detector was given,
            // which is today: one already past means tomorrow was meant.
            time: date > now ? date : nextTime(matching: date, after: now)
        )
    }

    /// The clock reading the model gave, as a date — if the speaker named that
    /// hour themselves.
    ///
    /// Every number is a suggestion to be checked. An hour outside a day, or a
    /// day count beyond a month, is a model that has lost its place. And an
    /// hour that appears nowhere in what was said is one it invented: measured
    /// on 2026-09-02, "wake me at five" came back as midnight and "in 20
    /// minutes" as eleven o'clock. Five and twenty are in those sentences;
    /// midnight and eleven are not.
    static func time(
        from understood: UnderstoodReminder,
        in spoken: String,
        now: Date = Date()
    ) -> Date? {
        guard let hour = understood.hour, (0...23).contains(hour) else { return nil }
        let named = numbersNamed(in: spoken)
        // A twenty-four hour reading of an hour spoken as one of twelve: seven
        // in the evening is nineteen, and midnight is twelve.
        guard named.contains(hour) || named.contains(hour % 12)
            || (hour % 12 == 0 && named.contains(12)) else { return nil }
        let minute = understood.minute ?? 0
        guard (0...59).contains(minute) else { return nil }
        let days = understood.daysFromToday ?? 0
        guard (0...31).contains(days) else { return nil }

        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: days, to: now),
              let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        else { return nil }
        // The clock the model was told the time by, handed back as the answer.
        // Asked for a reminder with no time in it — "buy some milk" — it gave
        // the minute it was called, and nobody asks to be reminded of
        // something now.
        guard abs(time.timeIntervalSince(now)) > 120 else { return nil }
        // Said of today, and today's has gone: the next one is what was meant.
        // A day the model counted out stands as it is, even if it has passed.
        guard days == 0, time <= now else { return time }
        return nextTime(matching: time, after: now)
    }

    /// The numbers the sentence says out loud, however it says them.
    ///
    /// Three ways, none of which needs a vocabulary here. A word on its own is
    /// read by `NumberFormatter` — "five", 「十五」. A run of characters that
    /// are numbers is read the same way and then character by character, which
    /// is what finds 「三」 in 「午後三時」: Unicode knows its value, and a
    /// sentence with no spaces in it never offered a word to read.
    static func numbersNamed(in spoken: String) -> Set<Int> {
        let spelled = NumberFormatter()
        spelled.numberStyle = .spellOut
        var numbers: Set<Int> = []

        func read(_ run: some StringProtocol) {
            if let digits = Int(run) {
                numbers.insert(digits)
            } else if let word = spelled.number(from: String(run).lowercased()) {
                numbers.insert(word.intValue)
            }
        }

        for token in spoken.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            read(token)
        }
        var run = ""
        for character in spoken + " " {
            guard let value = character.wholeNumberValue else {
                // However short: 「9時に薬を飲む」 offers the 9 to nothing else,
                // there being no space anywhere in it to split on.
                if !run.isEmpty { read(run) }
                run = ""
                continue
            }
            // 「三」 is three wherever it stands; the 2 of "20" is not two. Only
            // a numeral that does not take its value from its position counts
            // on its own.
            if character.unicodeScalars.first?.properties.numericType == .numeric {
                numbers.insert(value)
            }
            run.append(character)
        }
        return numbers
    }

    private static func understand(_ spoken: String, now: Date) async -> ModelAnswer {
        let session = LanguageModelSession(
            instructions: """
                You read what someone said out loud into a reminder. \
                Give the words for the reminder itself, keeping the words they \
                used and dropping only the ones that ask for a reminder or name \
                a time. Answer in the language they spoke. \
                Give the hour and minute on a 24-hour clock, and how many days \
                from today they meant, ONLY if they named a time themselves. \
                Leave the hour and minute empty when they named none. The \
                current time is told to you so that you can work out what \
                "tomorrow" or "this evening" means, and MUST NOT be answered \
                with as if they had asked for it.
                """
        )
        let clock = now.formatted(.dateTime.weekday(.wide).hour().minute())
        do {
            let response = try await session.respond(
                to: "It is \(clock). They said: \(spoken)",
                generating: UnderstoodReminder.self
            )
            return .read(response.content)
        } catch {
            await PebbleDiagnostics.shared.record(
                category: "voice",
                message: "The model would not read the reminder: \(error)"
            )
            return .nothing
        }
    }

    /// Words and particles whose only job was to attach the time that has just
    /// been cut out. "Buy milk at" is not what anyone said.
    private static let timeJoining: Set<String> = [
        "at", "on", "by", "in", "for", "around", "before", "after", "until", "till",
        "next", "this", "the", "of",
    ]

    /// Whatever is left once the time is cut out is still a sentence with a hole
    /// in it, so the words that led into the hole go with it.
    private static func tidied(_ text: String, fallingBackTo whole: String) -> String {
        var words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        while let first = words.first, timeJoining.contains(first.lowercased()) {
            words.removeFirst()
        }
        while let last = words.last, timeJoining.contains(last.lowercased()) {
            words.removeLast()
        }
        let tidied = words
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.，、。にはでを"))
        return tidied.isEmpty ? whole : tidied
    }

    private static func nextTime(matching date: Date, after now: Date) -> Date {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        return calendar.nextDate(
            after: now,
            matching: time,
            matchingPolicy: .nextTime
        ) ?? date
    }
}

@Generable(description: "A reminder someone asked for out loud")
struct UnderstoodReminder {
    @Guide(description: "What to be reminded of, in the words they used, with no time or date")
    var title: String
    @Guide(description: "The hour they meant, on a 24-hour clock, or nothing if they named no time")
    var hour: Int?
    @Guide(description: "The minutes past that hour, or nothing")
    var minute: Int?
    @Guide(description: "0 if they meant today, 1 for tomorrow, and so on")
    var daysFromToday: Int?
}
