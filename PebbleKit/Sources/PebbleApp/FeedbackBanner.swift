import SwiftUI

/// The one place a `FeatureFeedback` is drawn.
///
/// Nothing, when there is nothing to say — so a screen writes
/// `FeedbackBanner(feedback: model.weather.feedback)` rather than unwrapping an
/// optional itself and choosing a glyph while it is there.
struct FeedbackBanner: View {
    var feedback: FeatureFeedback?

    var body: some View {
        if let feedback {
            Label(feedback.message, systemImage: systemImage(for: feedback))
                .font(.footnote)
                .foregroundStyle(foregroundStyle(for: feedback))
        }
    }

    private func systemImage(for feedback: FeatureFeedback) -> String {
        switch feedback {
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

#Preview("Nothing to say") {
    List {
        FeedbackBanner(feedback: nil)
        Text("A banner with no feedback takes no room.")
    }
}
