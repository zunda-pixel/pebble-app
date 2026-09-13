import Foundation
import PebbleProtocol

extension AppModel {
    /// Keeps a pin or reminder the watch made itself.
    ///
    /// The watch does not wait to be asked: a reminder dictated to it is
    /// written to its own database and offered to the phone a moment later. It
    /// arrives by id, so the same one offered twice replaces itself rather than
    /// appearing twice — which is also how an edit made on the watch, a
    /// postponed reminder, lands here.
    func keep(_ item: TimelinePin, from connection: WatchConnection) async {
        switch item.kind {
        case .reminder:
            timeline.reminders.removeAll { $0.id == item.id }
            timeline.reminders.append(item)
            timeline.reminders.sort { $0.timestamp < $1.timestamp }
            try? await reminderStore.save(timeline.reminders)
            await noteHeld(item.id, by: connection, in: reminderStore)
            // Written where the reader will look for it: a reminder spoken to
            // the watch belongs in the app they keep their timeline.reminders in, and it
            // goes there now rather than at the next sweep, because the watch
            // may be put down before then.
            if item.timestamp > .now { await mirrorInRemindersApp(item) }
        case .pin, .notification:
            timeline.pins.removeAll { $0.id == item.id }
            timeline.pins.append(item)
            try? await timelineStore.save(timeline.pins)
            await noteHeld(item.id, by: connection, in: timelineStore)
        }
        await DiagnosticLog.shared.record(
            category: "timeline",
            message: "kept a \(item.kind) the watch made, for \(item.timestamp)"
        )
    }

    /// Writes down that this watch has this item.
    ///
    /// The record is named for what the app wrote, but what it is *for* is
    /// knowing what to take back — and the watch holding one it made itself is
    /// the same problem. Without this, deleting a dictated reminder while the
    /// watch was away left it on the watch: nothing had written it, so nothing
    /// could name it afterwards.
    private func noteHeld(
        _ id: UUID,
        by connection: WatchConnection,
        in library: TimelinePinStore
    ) async {
        let watchID = connection.watch.id
        var held = (try? await library.writtenPinIDs(watchID: watchID)) ?? []
        held.insert(id)
        try? await library.setWrittenPinIDs(held, watchID: watchID)
    }
}
