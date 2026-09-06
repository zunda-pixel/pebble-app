import SwiftUI
// For `Date.RelativeFormatStyle`, which `MemberImportVisibility` will not lend
// out through the SwiftUI import.
import Foundation

/// The one place a `FeatureFeedback` is drawn.
///
/// Nothing, when there is nothing to say — so a screen writes
/// `FeedbackBanner(feedback: model.weather.feedback)` rather than unwrapping an
/// optional itself and choosing a glyph while it is there.
struct FeedbackBanner: View {
    var feedback: FeatureFeedback?

    var body: some View {
        if let feedback {
            VStack(alignment: .leading, spacing: 2) {
                Label(feedback.message, systemImage: systemImage(for: feedback))
                    .font(.footnote)
                    .foregroundStyle(foregroundStyle(for: feedback))
                FeedbackAge(at: feedback.at)
            }
        }
    }

    private func systemImage(for feedback: FeatureFeedback) -> String {
        switch feedback.kind {
        case .progress: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    /// A failure is the only one worth colour. Progress and success are the app
    /// saying what it did, and a screen full of green is a screen nobody reads.
    private func foregroundStyle(for feedback: FeatureFeedback) -> HierarchicalShapeStyle {
        feedback.isFailure ? .primary : .secondary
    }
}

/// How long ago a banner's message was true.
///
/// Here because these messages are never taken away: something said while the
/// watch was syncing is still on the screen when the screen is opened again
/// tomorrow, and "3 health updates received from the watch" gives no hint which
/// of the two it is.
private struct FeedbackAge: View {
    var at: Date

    var body: some View {
        // Said again every minute. A relative time drawn once would still read
        // "now" an hour later, which is a new way of being wrong about the very
        // thing the time was added to settle — and the view has no other reason
        // to be redrawn while it sits there.
        //
        // `.named` rather than `.numeric` because numeric turns a message just
        // written into "in 0 seconds", reading as something about to happen.
        //
        // Spelled out because this module has a `TimelineView` of its own — the
        // screen showing the watch's pins — which otherwise wins the name and
        // reports that `AppModel` has no member `periodic`.
        SwiftUI.TimelineView(.periodic(from: at, by: 60)) { _ in
            Text(at, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Progress") {
    List {
        FeedbackBanner(feedback: .progress("Installing Orbit…"))
    }
}

#Preview("Success") {
    List {
        FeedbackBanner(feedback: .success("Orbit was installed."))
    }
}

#Preview("Failure") {
    List {
        FeedbackBanner(feedback: .failure("The watch refused the app: its storage is full."))
    }
}

#Preview("Said a while ago") {
    List {
        FeedbackBanner(feedback: .success(
            "3 health update(s) received from the watch.",
            at: Date(timeIntervalSinceNow: -3 * 60 * 60)
        ))
    }
}

#Preview("Nothing to say") {
    List {
        FeedbackBanner(feedback: nil)
        Text("A banner with no feedback takes no room.")
    }
}
