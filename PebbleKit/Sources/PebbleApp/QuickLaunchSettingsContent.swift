import PebbleProtocol
import SwiftUI

/// What a long press of each button launches.
///
/// The candidates are the watch's installed applications and watchfaces, plus
/// the one system app worth naming: the Quiet Time toggle, which is what the
/// firmware itself puts on Back.
struct QuickLaunchSettingsContent: View {
    var assignments: (QuickLaunchButton) -> QuickLaunchAssignment
    var applications: [WatchApplication]
    var feedback: FeatureFeedback?
    var setAssignment: (QuickLaunchButton, QuickLaunchAssignment) -> Void

    private func title(for button: QuickLaunchButton) -> LocalizedStringKey {
        switch button {
        case .up: "Hold Up"
        case .down: "Hold Down"
        case .select: "Hold Select"
        case .back: "Hold Back"
        }
    }

    private func isUnnamed(_ id: UUID) -> Bool {
        id != QuickLaunchAssignment.invalidID
            && id != QuickLaunchAssignment.quietTimeToggleID
            && !applications.contains { $0.id == id }
    }

    private func binding(for button: QuickLaunchButton) -> Binding<UUID> {
        Binding(
            get: {
                let assignment = assignments(button)
                return assignment.isEnabled ? assignment.applicationID : QuickLaunchAssignment.invalidID
            },
            set: { id in
                setAssignment(
                    button,
                    id == QuickLaunchAssignment.invalidID
                        ? .off
                        : QuickLaunchAssignment(isEnabled: true, applicationID: id)
                )
            }
        )
    }

    var body: some View {
        Form {
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }
            Section {
                ForEach(QuickLaunchButton.allCases, id: \.self) { button in
                    Picker(title(for: button), selection: binding(for: button)) {
                        Text("Off").tag(QuickLaunchAssignment.invalidID)
                        Text("Focus").tag(QuickLaunchAssignment.quietTimeToggleID)
                        ForEach(applications) { application in
                            Text(application.displayName).tag(application.id)
                        }
                        // An app assigned on the wrist that this phone cannot
                        // name — a system app, or something since uninstalled.
                        // Without its own row the picker would show nothing
                        // selected, and choosing anything else would lose it.
                        if isUnnamed(binding(for: button).wrappedValue) {
                            Text("Unnamed App").tag(binding(for: button).wrappedValue)
                        }
                    }
                }
            } footer: {
                Text("Holding a button on the watchface opens the app assigned to it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Quick Launch"))
    }
}

#Preview("Quick Launch") {
    NavigationStack {
        QuickLaunchSettingsContent(
            assignments: { .firmwareDefault(for: $0) },
            applications: PreviewSamples.watchApplications,
            feedback: nil,
            setAssignment: { _, _ in }
        )
    }
}
