import Foundation
import PebbleProtocol

extension AppModel {
    /// Keeps a pin or reminder the watch made itself.
    ///
    /// The watch does not wait to be asked: a reminder dictated to it is
    /// written to its own database and offered to the phone a moment later. It
    /// arrives by id, so the same one offered twice replaces itself rather than
    /// appearing twice.
    func keep(_ item: PebbleTimelinePin) async {
        switch item.kind {
        case .reminder:
            reminders.removeAll { $0.id == item.id }
            reminders.append(item)
            reminders.sort { $0.timestamp < $1.timestamp }
            try? await reminderLibrary.save(reminders)
        case .pin, .notification:
            timelinePins.removeAll { $0.id == item.id }
            timelinePins.append(item)
            try? await timelineLibrary.save(timelinePins)
        }
        await PebbleDiagnostics.shared.record(
            category: "timeline",
            message: "kept a \(item.kind) the watch made, for \(item.timestamp)"
        )
    }
}
