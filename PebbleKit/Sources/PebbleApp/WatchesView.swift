import SwiftUI
import PebbleProtocol

struct WatchesView: View {
    var model: AppModel
    @State private var isAddingWatch = false

    private var listedWatchIDs: [WatchID] {
        let savedIDs = model.watches.saved.map(\.id)
        let unsavedConnected = model.connections
            .map(\.watch.id)
            .filter { !savedIDs.contains($0) }
        return unsavedConnected + savedIDs
    }

    var body: some View {
        WatchesContent(
            watches: listedWatchIDs.map { WatchSummary(watchID: $0, model: model) },
            feedback: model.watches.feedback,
            addWatch: { isAddingWatch = true },
            destination: { watch in
                WatchDetailView(model: model, watchID: watch.id)
            }
        )
        .task { await model.loadSavedWatches() }
        .sheet(isPresented: $isAddingWatch) {
            AddWatchSheet(model: model)
        }
        .onWindowMessage(ScanRequest.self, from: model) { _ in
            isAddingWatch = true
        }
    }
}

struct WatchesContent<Destination: View>: View {
    var watches: [WatchSummary]
    var feedback: FeatureFeedback?
    var addWatch: () -> Void
    @ViewBuilder var destination: (WatchSummary) -> Destination

    var body: some View {
        List {
            // Above the watches, not below them. It carries the connection
            // failures — the long one about the watch having forgotten this
            // phone — and at the foot of the list that sat past every watch.
            // `AddWatchContent` in this file already does it this way.
            FeedbackBanner(feedback: feedback)
            if watches.isEmpty {
                ContentUnavailableView {
                    Label("No Devices", systemImage: "applewatch")
                } description: {
                    Text("Add a Pebble 2 Duo, Pebble Time 2, or Pebble Round 2.")
                } actions: {
                    Button("Add Watch", systemImage: "plus", action: addWatch)
                }
            } else {
                Section("My Watches") {
                    ForEach(watches) { watch in
                        NavigationLink {
                            destination(watch)
                        } label: {
                            WatchListRow(watch: watch)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("Devices"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Watch", systemImage: "plus", action: addWatch)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct WatchListRow: View {
    var watch: WatchSummary

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                if watch.phase != nil {
                    if let batteryLevel = watch.batteryLevel {
                        Text(batteryLevel, format: .percent)
                    }
                } else if let lastConnectedAt = watch.lastConnectedAt {
                    Text(lastConnectedAt, format: .relative(presentation: .named))
                }

                status
            }
        } label: {
            Text(watch.name)
            if let displayName = watch.model?.displayName {
                Text(displayName)
            }
        }
    }

    // A watch in recovery firmware is connected and yet does nothing the rest of
    // the app offers, so saying only "Connected" leaves the reader waiting.
    @ViewBuilder
    private var status: some View {
        switch watch.phase {
        case .connected where watch.isRunningRecoveryFirmware:
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Firmware Required")
            }
            .foregroundStyle(.orange)
        case .connected:
            HStack {
                Image(systemName: "checkmark.circle.fill")
                Text("Connected")
            }
            .foregroundStyle(.green)
        case .reconnecting:
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Reconnecting…")
            }
            .foregroundStyle(.orange)
        case .disconnected, nil:
            HStack {
                Image(systemName: "applewatch.slash")
                Text("Not connected")
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct DiscoveredWatchRow: View {
    var watch: DiscoveredWatch
    var connect: () -> Void

    var body: some View {
        Button(action: connect) {
            LabeledContent {
                Text("\(watch.signalStrength) dBm")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(watch.name)
                        Text(watch.model.displayName)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Connects to this watch"))
    }
}

#Preview("One connected, one away") {
    NavigationStack {
        WatchesContent(
            watches: [
                PreviewSamples.connectedSummary,
                PreviewSamples.recoverySummary,
                PreviewSamples.savedSummary,
            ],
            feedback: nil,
            addWatch: {},
            destination: { watch in Text(verbatim: watch.name) }
        )
    }
}

#Preview("No watches") {
    NavigationStack {
        WatchesContent(
            watches: [],
            feedback: .failure("Bluetooth is off."),
            addWatch: {},
            destination: { _ in EmptyView() }
        )
    }
}
