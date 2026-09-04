import SwiftUI

/// One screen of a watch's first setup.
enum WatchSetupStep: String, Equatable, Identifiable, CaseIterable {
    case welcome
    case firmware
    case permissions
    case finished

    var id: String { rawValue }

    /// Firmware comes before the permissions: a watch in its recovery firmware
    /// accepts nothing else, so an allowed calendar would have nowhere to go.
    static func steps(
        isRunningRecoveryFirmware: Bool,
        permissions: PhonePermissions
    ) -> [WatchSetupStep] {
        var steps: [WatchSetupStep] = [.welcome]
        if isRunningRecoveryFirmware {
            steps.append(.firmware)
        }
        if PhonePermissionKind.asked.contains(where: { $0.isWorthAsking(in: permissions) }) {
            steps.append(.permissions)
        }
        steps.append(.finished)
        return steps
    }
}

extension PhonePermissionKind {
    /// Leaves out what is settled and what no answer here could change: a phone
    /// with no health data, or a refusal a device policy made.
    func isWorthAsking(in permissions: PhonePermissions) -> Bool {
        switch state(in: permissions) {
        case .allowed, .unavailable, .restricted: false
        case .notDetermined, .partly, .denied, .unknown: true
        }
    }

    /// Given a row of its own, which is everything this phone has an answer for
    /// — including what is already allowed, so that one screen shows the lot.
    func isListed(in permissions: PhonePermissions) -> Bool {
        switch state(in: permissions) {
        case .unavailable, .restricted: false
        case .allowed, .notDetermined, .partly, .denied, .unknown: true
        }
    }
}

/// What a watch's first connection opens: the firmware it may need, then each
/// permission on its own screen.
///
/// The system's own question is what actually grants anything, so every step
/// here is the sentence that goes in front of it.
struct WatchSetupView<FirmwareDestination: View>: View {
    var watchName: String
    var isRunningRecoveryFirmware: Bool
    var permissions: PhonePermissions
    var request: (PhonePermissionKind) async -> Void
    /// Read again after each answer: the system tells nobody what was chosen.
    var readPermissions: () -> PhonePermissions = { PhonePermissions.current() }
    var openSettings: () -> Void = { openPrivacySettings() }
    /// Which step to open on, so a preview can show the one it is about.
    var startAt: WatchSetupStep = .welcome
    @ViewBuilder var firmwareDestination: () -> FirmwareDestination
    var finish: () -> Void

    // Settled when the flow opens. Rebuilding it as answers arrive would take
    // the step being read out from under the reader.
    @State private var steps: [WatchSetupStep] = []
    @State private var stepIndex = 0
    @State private var isAsking = false
    /// What the toggles are drawn from, so an answer shows on the screen that
    /// asked for it.
    @State private var granted: PhonePermissions?

    private var step: WatchSetupStep {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : .welcome
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(stepIndex + 1), total: Double(max(steps.count, 1)))
                    .padding([.horizontal, .top])
                page
            }
            .navigationTitle(Text("Set Up \(watchName)"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close, action: finish)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 460)
        .task {
            guard steps.isEmpty else { return }
            steps = WatchSetupStep.steps(
                isRunningRecoveryFirmware: isRunningRecoveryFirmware,
                permissions: permissions
            )
            stepIndex = steps.firstIndex(of: startAt) ?? 0
            granted = permissions
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            WatchSetupPage(
                systemImage: "applewatch.radiowaves.left.and.right",
                title: Text("\(watchName) is connected"),
                message: Text("A few things are needed before it can show your day, your reminders, and the weather. They are all on the next screen, and any of them can wait.")
            ) {
                Button("Continue", action: advance)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .firmware:
            WatchSetupPage(
                systemImage: "lifepreserver.fill",
                title: Text("\(watchName) needs firmware"),
                message: Text("It started its recovery firmware, which can do one thing: take a new copy of PebbleOS. Everything else comes back once that is installed.")
            ) {
                NavigationLink {
                    firmwareDestination()
                } label: {
                    Text("Install Firmware")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Later", action: advance)
            }
        case .permissions:
            permissionsPage
        case .finished:
            WatchSetupPage(
                // Not "Ready": that key is the dictation recognizer's state.
                systemImage: "checkmark.circle.fill",
                title: Text("Setup Complete"),
                message: Text("Anything left unanswered can be granted later in Settings, which also shows what this app has been allowed to read.")
            ) {
                Button(role: .confirm, action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var permissionsPage: some View {
        let state = granted ?? permissions
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "switch.2")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("What the watch may use")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Turning one on asks the system for it. Anything left off can be turned on later in Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                // Drawn from the permissions the flow opened with, so a row does
                // not vanish from under the finger that just answered it.
                ForEach(PhonePermissionKind.asked.filter { $0.isListed(in: permissions) }) { kind in
                    PermissionToggleRow(
                        kind: kind,
                        state: kind.state(in: state),
                        isAsking: isAsking,
                        allow: { allow(kind) },
                        openSettings: openSettings
                    )
                }
            }
            .formStyle(.grouped)

            Button("Continue", action: advance)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isAsking)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func advance() {
        guard stepIndex + 1 < steps.count else {
            finish()
            return
        }
        stepIndex += 1
    }

    private func allow(_ kind: PhonePermissionKind) {
        isAsking = true
        Task {
            await request(kind)
            granted = readPermissions()
            isAsking = false
        }
    }
}

/// One permission as a switch.
///
/// A switch that only goes one way, because nothing an app does takes a
/// permission back: what is on is left on and disabled, and a refusal is not a
/// switch at all — only the privacy settings can undo one.
private struct PermissionToggleRow: View {
    var kind: PhonePermissionKind
    var state: PhonePermissionState
    var isAsking: Bool
    var allow: () -> Void
    var openSettings: () -> Void

    var body: some View {
        if state == .denied {
            LabeledContent {
                Button("Settings", systemImage: "gear", action: openSettings)
                    .accessibilityLabel(Text("Open Privacy Settings"))
            } label: {
                label
            }
        } else {
            Toggle(isOn: Binding(get: { state == .allowed }, set: { isOn in
                if isOn {
                    allow()
                }
            })) {
                label
            }
            .disabled(state == .allowed || isAsking)
        }
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: kind.systemImage)
        }
    }
}

private struct WatchSetupPage<Actions: View>: View {
    var systemImage: String
    var title: Text
    var message: Text
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            title
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            message
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: 12) {
                actions()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The watch and the permissions this flow is about, taken at the moment it
/// opens so that the steps do not depend on which task ran first.
struct WatchSetupContext: Identifiable, Equatable {
    var watchID: String
    var permissions: PhonePermissions

    var id: String { watchID }
}

struct WatchSetupSheet: View {
    var model: AppModel
    var context: WatchSetupContext
    var finish: () -> Void

    private var watch: WatchSummary {
        WatchSummary(watchID: context.watchID, model: model)
    }

    var body: some View {
        WatchSetupView(
            watchName: watch.name,
            isRunningRecoveryFirmware: watch.isRunningRecoveryFirmware,
            permissions: context.permissions,
            request: { await model.requestPhonePermission($0) },
            firmwareDestination: { FirmwareView(model: model, watchID: context.watchID) },
            finish: finish
        )
    }
}

// Built outside the previews: `#Preview` cannot see the initializer another
// macro generates for `PhonePermissions`.
private enum SetupPreview {
    static let nothingAsked = PhonePermissions()
    static let allAllowed = PhonePermissions(
        bluetooth: .allowed,
        calendar: .allowed,
        reminders: .allowed,
        location: .allowed,
        health: .allowed
    )
    static let someAllowed = PhonePermissions(
        bluetooth: .allowed,
        calendar: .allowed,
        reminders: .notDetermined,
        location: .allowed,
        health: .notDetermined
    )
    static let calendarRefused = PhonePermissions(
        bluetooth: .allowed,
        calendar: .denied,
        reminders: .allowed,
        location: .allowed,
        health: .allowed
    )
}

#Preview("Welcome") {
    WatchSetupView(
        watchName: "Pebble 5209",
        isRunningRecoveryFirmware: false,
        permissions: SetupPreview.nothingAsked,
        request: { _ in },
        readPermissions: { SetupPreview.nothingAsked },
        openSettings: {},
        firmwareDestination: { EmptyView() },
        finish: {}
    )
}

#Preview("Needs Firmware") {
    WatchSetupView(
        watchName: "Pebble 5209",
        isRunningRecoveryFirmware: true,
        permissions: SetupPreview.allAllowed,
        request: { _ in },
        readPermissions: { SetupPreview.allAllowed },
        openSettings: {},
        startAt: .firmware,
        firmwareDestination: { Text(verbatim: "Firmware") },
        finish: {}
    )
}

#Preview("Switches") {
    WatchSetupView(
        watchName: "Pebble 5209",
        isRunningRecoveryFirmware: false,
        permissions: SetupPreview.someAllowed,
        request: { _ in },
        readPermissions: { SetupPreview.someAllowed },
        openSettings: {},
        startAt: .permissions,
        firmwareDestination: { EmptyView() },
        finish: {}
    )
}

#Preview("Refused Calendar") {
    WatchSetupView(
        watchName: "Pebble 5209",
        isRunningRecoveryFirmware: false,
        permissions: SetupPreview.calendarRefused,
        request: { _ in },
        readPermissions: { SetupPreview.calendarRefused },
        openSettings: {},
        startAt: .permissions,
        firmwareDestination: { EmptyView() },
        finish: {}
    )
}
