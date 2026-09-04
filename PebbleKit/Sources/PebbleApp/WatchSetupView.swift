import SwiftUI

/// One screen of a watch's first setup.
enum WatchSetupStep: Equatable, Identifiable {
    case welcome
    case firmware
    case permission(PhonePermissionKind)
    case finished

    var id: String {
        switch self {
        case .welcome: "welcome"
        case .firmware: "firmware"
        case .permission(let kind): "permission.\(kind.rawValue)"
        case .finished: "finished"
        }
    }

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
        steps += PhonePermissionKind.asked
            .filter { $0.isWorthAsking(in: permissions) }
            .map { .permission($0) }
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
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            WatchSetupPage(
                systemImage: "applewatch.radiowaves.left.and.right",
                title: Text("\(watchName) is connected"),
                message: Text("A few things are needed before it can show your day, your reminders, and the weather. Each one is asked for on its own screen, and any of them can wait.")
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
        case .permission(let kind):
            permissionPage(kind)
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

    @ViewBuilder private func permissionPage(_ kind: PhonePermissionKind) -> some View {
        let isRefused = kind.state(in: permissions) == .denied
        WatchSetupPage(
            systemImage: kind.systemImage,
            title: Text(kind.title),
            message: Text(kind.explanation)
        ) {
            if isRefused {
                // Asking again after a refusal raises nothing at all.
                Button("Open Privacy Settings", systemImage: "gear", action: openSettings)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Allow") { allow(kind) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAsking)
            }
            Button("Later", action: advance)
                .disabled(isAsking)
        }
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
            isAsking = false
            advance()
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
        openSettings: {},
        startAt: .firmware,
        firmwareDestination: { Text(verbatim: "Firmware") },
        finish: {}
    )
}

#Preview("Refused Calendar") {
    WatchSetupView(
        watchName: "Pebble 5209",
        isRunningRecoveryFirmware: false,
        permissions: SetupPreview.calendarRefused,
        request: { _ in },
        openSettings: {},
        startAt: .permission(.calendar),
        firmwareDestination: { EmptyView() },
        finish: {}
    )
}
