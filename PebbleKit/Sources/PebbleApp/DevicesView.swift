import SwiftUI
import PebbleProtocol

struct DevicesView: View {
    var model: AppModel
    @State private var isAddingWatch = false

    private var listedWatchIDs: [WatchID] {
        let savedIDs = model.savedWatches.map(\.id)
        let unsavedConnected = model.connections
            .map(\.watch.id)
            .filter { !savedIDs.contains($0) }
        return unsavedConnected + savedIDs
    }

    var body: some View {
        DevicesContent(
            watches: listedWatchIDs.map { WatchSummary(watchID: $0, model: model) },
            feedback: model.watchManagementFeedback,
            addWatch: { isAddingWatch = true },
            destination: { watch in
                WatchDetailView(model: model, watchID: watch.id)
            }
        )
        .task { await model.loadSavedWatches() }
        .sheet(isPresented: $isAddingWatch) {
            AddWatchSheet(model: model)
        }
        .onPebbleMessage(PebbleScanRequest.self, from: model) { _ in
            isAddingWatch = true
        }
    }
}

struct DevicesContent<Destination: View>: View {
    var watches: [WatchSummary]
    var feedback: FeatureFeedback?
    var addWatch: () -> Void
    @ViewBuilder var destination: (WatchSummary) -> Destination

    var body: some View {
        List {
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

            FeedbackBanner(feedback: feedback)
        }
        .navigationTitle(Text("Devices"))
        .toolbar {
            ToolbarItem {
                Button("Add Watch", systemImage: "plus", action: addWatch)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

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
            managementFeedback: model.watchManagementFeedback,
            unknownBondedWatches: model.unknownBondedWatches,
            discoveredWatches: model.discoveredWatches,
            isConnecting: !model.connectingWatchIDs.isEmpty,
            connectUnknown: { watch in
                watchBeingAdded = watch.id
                Task { await model.connect(to: watch) }
            },
            connectDiscovered: { device in
                watchBeingAdded = device.id
                Task { await model.connect(to: device) }
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
                    .accessibilityLabel(Text("Bluetooth error"))
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
                    ForEach(discoveredWatches) { device in
                        DiscoveredDeviceRow(device: device) {
                            connectDiscovered(device)
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

struct DiscoveredDeviceRow: View {
    var device: DiscoveredWatch
    var connect: () -> Void

    var body: some View {
        Button(action: connect) {
            LabeledContent {
                Text("\(device.signalStrength) dBm")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(device.model.displayName)
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
        DevicesContent(
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
        DevicesContent(
            watches: [],
            feedback: .failure("Bluetooth is off."),
            addWatch: {},
            destination: { _ in EmptyView() }
        )
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
