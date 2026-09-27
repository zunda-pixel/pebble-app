import SwiftUI

/// What this app has been allowed to read, on a screen of its own.
///
/// Takes the states rather than reading them: the settings screen that pushes
/// this already watches for them changing while the app is in the background,
/// and one owner of that is enough. Pushed from there, this redraws when it
/// does.
struct PermissionsContent: View {
    var permissions: PhonePermissions

    var body: some View {
        Form {
            Section {
                permissionRow("Bluetooth", permissions.bluetooth)
                permissionRow("Calendar", permissions.calendar)
                permissionRow("Reminders", permissions.reminders)
                permissionRow("Location", permissions.location)
                permissionRow("Health", permissions.health)
            } footer: {
                Text("What this app has been allowed to read. Health shows whether it may write to your Health data: iOS gives no way to ask whether reading was allowed.")
            }
            Section {
                Button("Open Privacy Settings", systemImage: "gear") {
                    openPrivacySettings()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Permissions"))
    }

    private func permissionRow(
        _ name: LocalizedStringKey,
        _ state: PhonePermissionState
    ) -> some View {
        LabeledContent {
            Text(state.title)
                .foregroundStyle(state.isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        } label: {
            Text(name)
        }
    }
}

#Preview("Everything allowed") {
    NavigationStack {
        PermissionsContent(permissions: PreviewSamples.permissionsAllowed)
    }
}

#Preview("Some withheld") {
    NavigationStack {
        PermissionsContent(permissions: PreviewSamples.permissionsWithheld)
    }
}
