/// One of the watch's longer answers, asked for.
///
/// The three differ only in which collector reads the pieces and how long the
/// watch may go quiet, which is the transport's business; from the app's side
/// they are one question.
public enum WatchPullRequest: Equatable, Sendable {
    case screenshot
    /// Generation zero is the run the watch is in now, one the run before it.
    case logGeneration(UInt8)
    case file(GetBytesRequest)
}

/// What came back. One case per request, so a transport that answers with the
/// wrong one is caught at this boundary rather than by whoever asked.
public enum WatchPullAnswer: Equatable, Sendable {
    case screenshot(WatchScreenshot)
    /// Nil once asked for further back than the watch goes.
    case logLines([WatchLogLine]?)
    case bytes([UInt8])
}
