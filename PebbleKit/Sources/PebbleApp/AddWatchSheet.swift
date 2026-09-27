import PebbleProtocol
import SwiftUI

struct AddWatchSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    // So the sheet can close the moment that watch is connected, rather than when
    // everything the app then sends it has been sent.
    @State private var watchBeingAdded: WatchID?

    /// Asked of the watch that was tapped rather than of `connectionState`: this
    /// sheet scans in a loop the whole time it is open, and a scan in progress
    /// outranks a failure there — which is how a refused connect came to leave
    /// the screen exactly as it was.
    private var connectionFeedback: FeatureFeedback? {
        if let watchBeingAdded, let failure = model.connectionFailures[watchBeingAdded] {
            return .failure(failure.message)
        }
        guard case .failed(let error) = model.connectionState else { return nil }
        return .failure(error.message)
    }

    var body: some View {
        AddWatchContent(
            connectionFeedback: connectionFeedback,
            managementFeedback: model.watches.feedback,
            unknownBondedWatches: model.watches.unknownBonded,
            discoveredWatches: model.discoveredWatches,
            isConnecting: !model.connectingWatchIDs.isEmpty,
            connectUnknown: { watch in
                watchBeingAdded = watch.id
                Task { await model.connect(to: watch) }
            },
            connectDiscovered: { watch in
                watchBeingAdded = watch.id
                Task { await model.connect(to: watch) }
            },
            close: { dismiss() }
        )
        .onChange(of: model.connections.map(\.watch.id)) { _, connectedIDs in
            guard let watchBeingAdded, connectedIDs.contains(watchBeingAdded) else { return }
            dismiss()
        }
        .task {
            // Every pass has to suspend, including the failing one, or a transport that
            // refuses immediately spins.
            while !Task.isCancelled {
                await model.scan()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }
}

struct AddWatchContent: View {
    var connectionFeedback: FeatureFeedback?
    var managementFeedback: FeatureFeedback?
    var unknownBondedWatches: [UnknownBondedWatch]
    var discoveredWatches: [DiscoveredWatch]
    var isConnecting: Bool
    var connectUnknown: (UnknownBondedWatch) -> Void
    var connectDiscovered: (DiscoveredWatch) -> Void
    var close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                FeedbackBanner(feedback: connectionFeedback)
                FeedbackBanner(feedback: managementFeedback)

                if !unknownBondedWatches.isEmpty {
                    Section {
                        ForEach(unknownBondedWatches) { watch in
                            Button {
                                connectUnknown(watch)
                            } label: {
                                Label(watch.name, systemImage: "applewatch.radiowaves.left.and.right")
                            }
                            .disabled(isConnecting)
                        }
                    } header: {
                        Text("Already Paired")
                    } footer: {
                        Text("A watch that is paired with this phone but has not been added here. It cannot be found by scanning; it appears when it reaches the app by itself.")
                    }
                }

                Section {
                    ForEach(discoveredWatches) { watch in
                        DiscoveredWatchRow(watch: watch) {
                            connectDiscovered(watch)
                        }
                        .disabled(isConnecting)
                    }
                } header: {
                    HStack {
                        Text("Nearby")
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .navigationTitle(Text("Add Watch"))
            .toolbar {
                Button(role: .close, action: close)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

#Preview("Add watch") {
    AddWatchContent(
        connectionFeedback: nil,
        managementFeedback: nil,
        unknownBondedWatches: [
            UnknownBondedWatch(id: WatchID("bonded-watch"), name: "Pebble 33EE"),
        ],
        discoveredWatches: [PreviewSamples.discovered],
        isConnecting: false,
        connectUnknown: { _ in },
        connectDiscovered: { _ in },
        close: {}
    )
}

#Preview("Connecting") {
    AddWatchContent(
        connectionFeedback: nil,
        managementFeedback: nil,
        unknownBondedWatches: [],
        discoveredWatches: [PreviewSamples.discovered],
        isConnecting: true,
        connectUnknown: { _ in },
        connectDiscovered: { _ in },
        close: {}
    )
}

#Preview("Connection failed") {
    AddWatchContent(
        connectionFeedback: .failure(WatchConnectionError.connectionTimedOut.message),
        managementFeedback: nil,
        unknownBondedWatches: [],
        discoveredWatches: [PreviewSamples.discovered],
        isConnecting: false,
        connectUnknown: { _ in },
        connectDiscovered: { _ in },
        close: {}
    )
}

#Preview("Nothing nearby") {
    AddWatchContent(
        connectionFeedback: nil,
        managementFeedback: nil,
        unknownBondedWatches: [],
        discoveredWatches: [],
        isConnecting: false,
        connectUnknown: { _ in },
        connectDiscovered: { _ in },
        close: {}
    )
}
