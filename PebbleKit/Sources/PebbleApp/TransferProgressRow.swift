import SwiftUI
import PebbleProtocol

/// One transfer, as a bar and the bytes behind it.
///
/// The title is the caller's, because the two screens that show a transfer know
/// different halves of it: the library screen has a watch picker and so names
/// the application, while an application's own screen names the watch — and
/// shows one of these per watch, since an installed application is pushed to
/// every one that is connected.
struct TransferProgressRow: View {
    var title: String
    var systemImage: String
    var progress: PutBytesTransferProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            if progress.totalBytes > 0 {
                ProgressView(
                    value: Double(progress.bytesSent),
                    total: Double(progress.totalBytes)
                )
                Text("\(progress.bytesSent, format: .number) of \(progress.totalBytes, format: .number) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .accessibilityLabel(Text("Preparing installation"))
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Sending") {
    TransferProgressRow(
        title: PreviewSamples.watchApplications[0].displayName,
        systemImage: "arrow.down.app",
        progress: PreviewSamples.transferProgress
    )
    .padding()
}

#Preview("Preparing") {
    TransferProgressRow(
        title: PreviewSamples.watchApplications[0].displayName,
        systemImage: "arrow.down.app",
        progress: PutBytesTransferProgress(bytesSent: 0, totalBytes: 0)
    )
    .padding()
}
