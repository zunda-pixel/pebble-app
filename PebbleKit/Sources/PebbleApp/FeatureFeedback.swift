public import SwiftUI
// `at` is a `Date` in a public signature, so under `MemberImportVisibility`
// the module that declares it has to be imported here.
public import Foundation

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
///
/// It carries when it was said, too. Nothing here is ever taken away on a
/// timer — a message that disappears says nothing at all to a reader who
/// happened to be looking elsewhere — so one of these can sit on a screen long
/// after the fact. Without the time, an hour-old "3 health updates received
/// from the watch" reads exactly like one that has just arrived.
///
/// A struct rather than three cases carrying words, because the time belongs to
/// all three and every one of the hundred-odd places that writes one of these
/// says only what happened, leaving `at` to its default.
///
/// Not `Sendable`: `LocalizedStringKey` is not, and this never leaves the main
/// actor — it is written by a model and read by a view, both of which are on it.
public struct FeatureFeedback: Equatable {
    public enum Kind: Equatable, Sendable {
        /// Something is under way. Distinct from success so that a screen can
        /// show it beside a spinner and stop showing it when the work ends.
        case progress
        case success
        case failure
    }

    public var kind: Kind
    public var message: LocalizedStringKey
    /// When the feature had this to say.
    public var at: Date

    public static func progress(_ message: LocalizedStringKey, at: Date = .now) -> Self {
        Self(kind: .progress, message: message, at: at)
    }

    public static func success(_ message: LocalizedStringKey, at: Date = .now) -> Self {
        Self(kind: .success, message: message, at: at)
    }

    public static func failure(_ message: LocalizedStringKey, at: Date = .now) -> Self {
        Self(kind: .failure, message: message, at: at)
    }

    public var isFailure: Bool { kind == .failure }

    /// Equal when they say the same thing, whatever the clock said.
    ///
    /// The time is shown, not compared. A test asking whether a screen said
    /// "Local Pebble health data deleted." is asking about the words, and could
    /// never name the instant the model wrote them.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.message == rhs.message
    }
}
