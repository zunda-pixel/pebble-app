import SwiftUI

/// Writing the health archive, from asking for it to sharing it.
///
/// It used to be two menu items: one that wrote the file and said nothing, and
/// another that appeared afterwards to share it — so the only sign the first
/// had worked was that the second had turned up, and finding it meant opening
/// the menu again. One sheet does the whole job and stays open to show what
/// came of it.
struct HealthExportSheet: View {
    /// A file from an earlier export, so reopening this finds it rather than
    /// making the reader write it again.
    var existingExport: URL?
    var export: @MainActor () async -> URL?

    @State private var written: URL?
    @State private var isWorking = false
    @State private var hasFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let url = written ?? existingExport {
                        LabeledContent("File") {
                            Text(verbatim: url.lastPathComponent)
                        }
                        ShareLink(item: url) {
                            Label("Share Export", systemImage: "square.and.arrow.up")
                        }
                    } else if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Exporting…")
                        }
                    } else {
                        Button("Export Health Data", systemImage: "square.and.arrow.up") {
                            Task { await run() }
                        }
                    }
                    if hasFailed {
                        FeedbackBanner(feedback: .failure("Health data could not be exported."))
                    }
                } footer: {
                    Text("Every day the watch has recorded is written to one JSON file. It stays on this phone until you share it from here.")
                }
                // Offered again once there is a file, because the days on the
                // watch may have moved on since it was written.
                if written != nil || existingExport != nil {
                    Section {
                        Button("Export Again", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await run() }
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Export"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private func run() async {
        isWorking = true
        hasFailed = false
        let url = await export()
        isWorking = false
        if let url { written = url } else { hasFailed = true }
    }
}

#Preview("Nothing written yet") {
    HealthExportSheet(existingExport: nil, export: { nil })
}

#Preview("Already written") {
    HealthExportSheet(
        existingExport: URL(fileURLWithPath: "/tmp/pebble-health.json"),
        export: { URL(fileURLWithPath: "/tmp/pebble-health.json") }
    )
}
