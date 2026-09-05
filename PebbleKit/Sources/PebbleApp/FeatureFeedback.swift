public import SwiftUI

/// What one feature has to say about the last thing it was asked to do.
///
/// There were twelve of these on `AppModel`, all `LocalizedStringKey?`, under
/// two names — `…StatusMessage` and `…ErrorMessage` — that did not reliably
/// mean anything: the "status" ones carried refusals and the "error" ones
/// carried progress. Because the value said nothing about which it was, every
/// screen chose a glyph and a colour by guessing, and they disagreed: the same
/// kind of refusal was drawn with `info.circle` on one screen and
/// `exclamationmark.triangle.fill` on another, and a success came out in the
/// same grey as a failure.
///
/// Now the kind travels with the words, and `FeedbackBanner` is the only thing
/// that decides how a kind looks.
/// Not `Sendable`: `LocalizedStringKey` is not, and this never leaves the main
/// actor — it is written by a model and read by a view, both of which are on it.
public enum FeatureFeedback: Equatable {
    /// Something is under way. Distinct from success so that a screen can show
    /// it beside a spinner and stop showing it when the work ends.
    case progress(LocalizedStringKey)
    case success(LocalizedStringKey)
    case failure(LocalizedStringKey)

    public var message: LocalizedStringKey {
        switch self {
        case .progress(let message), .success(let message), .failure(let message):
            message
        }
    }

    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
