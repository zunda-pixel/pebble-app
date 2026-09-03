/// One of the things the watch can be asked about itself, named so that a
/// result can be shown beside the button that asked for it.
///
/// The four shared a single message before, which put every result in one
/// section at the end of a screen the buttons are spread across — a result no
/// one scrolled to, that the next operation was as likely to have written.
public enum WatchDiagnostic: Sendable, CaseIterable {
    case screenshot
    case watchLogs
    case coredump
    case timeline
}
