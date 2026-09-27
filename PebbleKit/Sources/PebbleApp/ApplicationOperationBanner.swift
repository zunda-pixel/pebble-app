import SwiftUI
import PebbleProtocol

/// What the library is in the middle of, and what went wrong doing it.
struct ApplicationOperationBanner: View {
    var operationFeedback: FeatureFeedback?
    var installingApplicationName: String?
    var installationProgress: PutBytesTransferProgress?
    var libraryFeedback: FeatureFeedback?
    /// Shown here as well as on the catalogue, because a package dropped on
    /// this screen is imported by the same call as the one the catalogue's
    /// button makes.
    var importFeedback: FeatureFeedback?

    private var isEmpty: Bool {
        operationFeedback == nil && libraryFeedback == nil && importFeedback == nil
            && (installingApplicationName == nil || installationProgress == nil)
    }

    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FeedbackBanner(feedback: operationFeedback)
                if let installingApplicationName, let installationProgress {
                    // Named for the application: this screen already knows
                    // which watch, from the picker at the top. An
                    // application's own screen is the other way round and
                    // names the watch.
                    TransferProgressRow(
                        title: installingApplicationName,
                        systemImage: "arrow.down.app",
                        progress: installationProgress
                    )
                }
                FeedbackBanner(feedback: libraryFeedback)
                FeedbackBanner(feedback: importFeedback)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

#Preview("Installing") {
    ApplicationOperationBanner(
        operationFeedback: .progress("Installing app…"),
        installingApplicationName: PreviewSamples.watchApplications[0].displayName,
        installationProgress: PreviewSamples.transferProgress,
        libraryFeedback: nil,
        importFeedback: nil
    )
}

#Preview("A refusal") {
    ApplicationOperationBanner(
        operationFeedback: nil,
        installingApplicationName: nil,
        installationProgress: nil,
        libraryFeedback: .failure("Another app operation is already in progress."),
        importFeedback: nil
    )
}
