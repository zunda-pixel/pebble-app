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
/// The time is found by `NSDataDetector` rather than asked of the language
/// model: a date is the part that has to be exactly right, and the detector
/// gives the same answer every time for a fraction of the fifteen seconds the
/// watch allows. The model is asked only to say the reminder in fewer words,
/// which is the part it is better at than any rule.
enum ReminderReading {
    /// How long the model may take before the detector's own wording is sent
    /// instead. The watch gives up on a session result after fifteen seconds,
    /// and transcribing has already spent some of that.
    static let modelDeadline = Duration.seconds(5)

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
            time: date > now ? date : tomorrow(date, after: now)
        )
    }

    /// The same reminder with the language model's shorter wording, when there
    /// is a model and it answers in time.
    static func readWithModel(_ spoken: String, now: Date = Date()) async -> SpokenReminder {
        let detected = read(spoken, now: now)
        guard SystemLanguageModel.default.isAvailable else { return detected }
        let shorter = await withTaskGroup(of: String?.self) { group in
            group.addTask { await shortened(spoken) }
            group.addTask {
                try? await Task.sleep(for: modelDeadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let shorter, !shorter.isEmpty else { return detected }
        return SpokenReminder(text: shorter, time: detected.time)
    }

    private static func shortened(_ spoken: String) async -> String? {
        let session = LanguageModelSession(
            instructions: """
                You turn what someone said out loud into the title of a reminder. \
                Keep the words they used. Drop anything that only asks for the \
                reminder to be made, and drop the time or date. \
                Answer in the language they spoke.
                """
        )
        do {
            let response = try await session.respond(
                to: "They said: \(spoken)",
                generating: SpokenReminderTitle.self
            )
            return response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await PebbleDiagnostics.shared.record(
                category: "voice",
                message: "The model would not shorten the reminder: \(error)"
            )
            return nil
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

    private static func tomorrow(_ date: Date, after now: Date) -> Date {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        return calendar.nextDate(
            after: now,
            matching: time,
            matchingPolicy: .nextTime
        ) ?? date
    }
}

@Generable(description: "The title of a reminder someone asked for out loud")
private struct SpokenReminderTitle {
    @Guide(description: "What to be reminded of, in as few words as they used, with no time or date")
    var title: String
}
