/// One of the things that can be asked for when something has gone wrong,
/// named so that a result can be shown beside the button that asked for it.
///
/// Four of these shared a single message before, which put every result in one
/// section at the end of a screen the buttons are spread across — a result no
/// one scrolled to, that the next operation was as likely to have written.
public enum WatchDiagnostic: Sendable, CaseIterable {
    case screenshot
    case watchLogs
    case coredump
    case timeline
    /// The report the phone writes about itself and the watch it is talking to.
    ///
    /// The only one here that is not asked of the watch, and the only one whose
    /// button is on the settings screen rather than a watch's own. It is here
    /// anyway, because what this enum is for is naming which button an answer
    /// belongs beside — and its answer used to be written to the application
    /// library's field, which put a failed report on the Apps tab while the
    /// settings screen, where it was asked for, said nothing at all.
    case report
}
