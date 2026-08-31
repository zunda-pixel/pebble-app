import API
import SwiftUI

/// One phone app's notifications, as the watch shows them.
struct NotificationAppView: View {
    var model: AppModel
    var app: NotificationSourceApp

    private var current: NotificationSourceApp {
        model.notificationSourceApps.first { $0.bundleID == app.bundleID } ?? app
    }

    var body: some View {
        Form {
            Section {
                Picker("Mute", selection: Binding(
                    get: { current.muteState },
                    set: { state in
                        Task {
                            await model.setNotificationSourceAppMute(
                                bundleID: app.bundleID,
                                muteState: state
                            )
                        }
                    }
                )) {
                    ForEach(NotificationAppMuteState.allCases, id: \.self) { state in
                        Text(state.title).tag(state)
                    }
                }
            } header: {
                Text("Notifications")
            }

            Section {
                Picker("Icon", selection: Binding(
                    get: { current.icon },
                    set: { icon in
                        Task {
                            await model.setNotificationSourceAppIcon(bundleID: app.bundleID, icon: icon)
                        }
                    }
                )) {
                    Text("Chosen by the Watch").tag(PebbleTimelineIcon?.none)
                    ForEach(PebbleTimelineIcon.choosable, id: \.self) { icon in
                        Text(icon.title).tag(PebbleTimelineIcon?.some(icon))
                    }
                }
            } header: {
                Text("Icon")
            } footer: {
                Text("The watch has a logo of its own for the apps it knows. Choosing one here is for the ones it does not.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: current.displayName))
    }
}
