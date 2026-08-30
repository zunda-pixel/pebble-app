import SwiftUI
import API

struct DevicesView: View {
    var model: AppModel
    @State private var isAddingWatch = false

    // Saved watches plus any connected watch that has not been saved yet.
    private var listedWatchIDs: [String] {
        let savedIDs = model.savedWatches.map(\.id)
        let unsavedConnected = model.connections
            .map(\.device.id)
            .filter { !savedIDs.contains($0) }
        return unsavedConnected + savedIDs
    }

    var body: some View {
        List {
            if listedWatchIDs.isEmpty {
                ContentUnavailableView {
                    Label("No Devices", systemImage: "applewatch")
                } description: {
                    Text("Add a Pebble 2 Duo, Pebble Time 2, or Pebble Round 2.")
                } actions: {
                    Button("Add Watch", systemImage: "plus") {
                        isAddingWatch = true
                    }
                }
            } else {
                Section("My Watches") {
                    ForEach(listedWatchIDs, id: \.self) { watchID in
                        NavigationLink {
                            WatchDetailView(model: model, watchID: watchID)
                        } label: {
                            WatchListRow(model: model, watchID: watchID)
                        }
                    }
                }
            }

            if let errorMessage = model.watchManagementErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Devices")
        .task { await model.loadSavedWatches() }
        .toolbar {
            ToolbarItem {
                Button("Add Watch", systemImage: "plus") {
                    isAddingWatch = true
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .sheet(isPresented: $isAddingWatch) {
            AddWatchSheet(model: model)
        }
        .onPebbleMessage(PebbleScanRequest.self, from: model) { _ in
            isAddingWatch = true
        }
    }
}

struct AddWatchSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if case .failed(let error) = model.connectionState {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Bluetooth error")
                        .accessibilityValue(error.message)
                }
                if let errorMessage = model.watchManagementErrorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                if !model.unknownBondedWatches.isEmpty {
                    Section {
                        ForEach(model.unknownBondedWatches) { watch in
                            Button {
                                Task {
                                    await model.connect(to: watch)
                                    if model.connections.contains(where: { $0.device.id == watch.id }) {
                                        dismiss()
                                    }
                                }
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
                    ForEach(model.discoveredDevices) { device in
                        DiscoveredDeviceRow(device: device) {
                            Task {
                                await model.connect(to: device)
                                if model.connections.contains(where: { $0.device.id == device.id }) {
                                    dismiss()
                                }
                            }
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
            .navigationTitle("Add Watch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .task {
            // Scan for the whole lifetime of the sheet; the task is cancelled
            // when the sheet closes and the loop ends after the current pass.
            // Every pass has to suspend, including the ones that return early
            // because a scan from a previous sheet is still running, otherwise
            // the loop starves the main actor and the app stops responding.
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

    private var isConnecting: Bool {
        !model.connectingDeviceIDs.isEmpty
    }
}

struct WatchListRow: View {
    var model: AppModel
    var watchID: String

    private var connection: WatchConnection? {
        model.connections.first { $0.device.id == watchID }
    }

    private var savedWatch: SavedPebbleWatch? {
        model.savedWatches.first { $0.id == watchID }
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                if let connection {
                    if let batteryLevel = connection.device.batteryLevel {
                        Text(batteryLevel, format: .percent)
                    }
                } else if let savedWatch {
                    Text(savedWatch.lastConnectedAt, format: .relative(presentation: .named))
                }
                
                switch connection?.phase {
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
        } label: {
            Text(connection?.device.name ?? savedWatch?.name ?? watchID)
            if let displayName = (connection?.device.model ?? savedWatch?.model)?.displayName {
                Text(displayName)
            }
        }
    }
}

struct WatchDetailView: View {
    var model: AppModel
    var watchID: String
    @Environment(\.dismiss) private var dismiss

    private var connection: WatchConnection? {
        model.connections.first { $0.device.id == watchID }
    }

    private var savedWatch: SavedPebbleWatch? {
        model.savedWatches.first { $0.id == watchID }
    }

    private var watchName: String {
        connection?.device.name ?? savedWatch?.name ?? watchID
    }

    /// What the Firmware row says before it is opened. A version is a version
    /// in any language, so it is the one part of this that is not translated.
    private var firmwareSummary: Text {
        if let journal = model.firmwareUpdateJournal, journal.deviceID == watchID {
            return journal.phase == .transferring || journal.phase == .installing
                ? Text("Installing…")
                : Text("Update waiting")
        }
        if connection?.device.isRunningRecoveryFirmware == true {
            return Text("Recovery firmware")
        }
        if let downloaded = model.downloadedFirmware {
            return Text("\(downloaded.versionTag) ready")
        }
        guard let version = connection?.device.firmwareVersion ?? savedWatch?.firmwareVersion else {
            return Text("Unknown")
        }
        return Text(verbatim: version)
    }

    var body: some View {
        Form {
            if connection?.device.isRunningRecoveryFirmware == true {
                Section {
                    Label(
                        "This watch started its recovery firmware. Install firmware to finish setting it up.",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }

            Section("Watch") {
                if let model = connection?.device.model ?? savedWatch?.model {
                    LabeledContent("Model", value: model.displayName)
                }
                if let serialNumber = connection?.device.serialNumber ?? savedWatch?.serialNumber {
                    LabeledContent("Serial Number", value: serialNumber)
                }
                if let batteryLevel = connection?.device.batteryLevel ?? savedWatch?.lastBatteryLevel {
                    LabeledContent("Battery", value: batteryLevel, format: .percent)
                }
                LabeledContent("Status") {
                    switch connection?.phase {
                    case .connected:
                        Text("Connected")
                    case .reconnecting:
                        Text("Reconnecting…")
                    case .disconnected, nil:
                        Text("Not connected")
                    }
                }
            }
            Section("Connection") {
                if connection == nil, let savedWatch {
                    Button("Connect", systemImage: "applewatch.radiowaves.left.and.right") {
                        Task { await model.connect(to: savedWatch) }
                    }
                    .disabled(model.connectingDeviceIDs.contains(watchID))
                }
                if savedWatch != nil {
                    Toggle("Connect Automatically", isOn: Binding(
                        get: { savedWatch?.automaticallyConnects ?? false },
                        set: { enabled in
                            Task { await model.setAutomaticallyConnects(enabled, watchID: watchID) }
                        }
                    ))
                }
                if connection != nil {
                    Button("Disconnect", role: .destructive) {
                        Task { await model.disconnect(deviceID: watchID) }
                    }
                }
            }
            Section("Notifications") {
                Button("Send Test Notification", systemImage: "bell.badge") {
                    Task { await model.sendTestNotification(deviceID: watchID) }
                }
                .disabled(connection?.isConnected != true)
                if let notificationStatusMessage = model.notificationStatusMessage {
                    Label(notificationStatusMessage, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink {
                    FirmwareView(model: model, watchID: watchID)
                } label: {
                    LabeledContent("Firmware") {
                        firmwareSummary
                    }
                }
            }
            Section {
                ConfirmingButton(
                    title: "Restart Watch",
                    systemImage: "arrow.clockwise",
                    question: "Restart \(watchName)?",
                    explanation: "The watch disconnects while it restarts.",
                    confirmationTitle: "Restart Watch",
                    confirmationRole: nil
                ) {
                    Task { await model.resetWatch(.restart, deviceID: watchID) }
                }
                .disabled(connection?.isConnected != true)
                ConfirmingButton(
                    title: "Restart into Recovery Firmware",
                    systemImage: "lifepreserver",
                    question: "Restart \(watchName) into recovery firmware?",
                    explanation: "The watch restarts into recovery firmware, where only firmware updates are available.",
                    confirmationTitle: "Restart into Recovery Firmware",
                    confirmationRole: nil
                ) {
                    Task { await model.resetWatch(.recoveryFirmware, deviceID: watchID) }
                }
                .disabled(connection?.isConnected != true)
                ConfirmingButton(
                    title: "Factory Reset",
                    systemImage: "trash",
                    role: .destructive,
                    question: "Erase \(watchName)?",
                    explanation: "Every app, watchface, and setting stored on the watch is erased. This cannot be undone.",
                    confirmationTitle: "Erase Watch"
                ) {
                    Task { await model.resetWatch(.factoryReset, deviceID: watchID) }
                }
                .disabled(connection?.isConnected != true)
                if let watchResetStatusMessage = model.watchResetStatusMessage {
                    Label(watchResetStatusMessage, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("The watch restarts without answering, so it disconnects immediately. A factory reset erases everything stored on the watch.")
            }
            Section {
                ConfirmingButton(
                    title: "Forget Watch",
                    role: .destructive,
                    question: "Forget \(watchName)?",
                    explanation: "Automatic reconnection information for this Pebble will be removed.",
                    confirmationTitle: "Forget Watch"
                ) {
                    Task {
                        await model.forgetWatch(id: watchID)
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(watchName)
    }
}

struct DiscoveredDeviceRow: View {
    var device: DiscoveredPebble
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
        .accessibilityHint("Connects to this watch")
    }
}
