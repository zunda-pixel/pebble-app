import SwiftUI
import PebbleProtocol

/// Everything about notifications, on a screen of its own.
///
/// Both kinds are here, because the difference between them is the thing worth
/// seeing side by side: the switches at the top gate a path this app is on — a
/// watch app's own JavaScript raising a notification, which this app then
/// writes to the watch — while the phone's apps reach the watch over ANCS
/// without passing through here at all, so that row leads to the watch's own
/// settings for them.
struct NotificationSettingsContent<PhoneAppsDestination: View>: View {
    var companionNotificationsEnabled: Bool
    var notificationPreferences: NotificationDeliveryPreferences
    var applications: [WatchApplication]
    var notificationSourceAppCount: Int
    var setCompanionNotificationsEnabled: (Bool) -> Void
    var setQuietHours: (_ enabled: Bool, _ start: Int?, _ end: Int?) -> Void
    var setNotificationsEnabled: (Bool, UUID) -> Void
    @ViewBuilder var phoneAppsDestination: () -> PhoneAppsDestination

    var body: some View {
        Form {
            Section {
                Toggle("Watch App Notifications", isOn: Binding(
                    get: { companionNotificationsEnabled },
                    set: { setCompanionNotificationsEnabled($0) }
                ))
                Toggle("Quiet Hours", isOn: Binding(
                    get: { notificationPreferences.quietHoursEnabled },
                    set: { value in setQuietHours(value, nil, nil) }
                ))
                if notificationPreferences.quietHoursEnabled {
                    Stepper(
                        "Starts at \(notificationPreferences.quietHoursStart):00",
                        value: Binding(
                            get: { notificationPreferences.quietHoursStart },
                            set: { value in setQuietHours(true, value, nil) }
                        ),
                        in: 0...23
                    )
                    Stepper(
                        "Ends at \(notificationPreferences.quietHoursEnd):00",
                        value: Binding(
                            get: { notificationPreferences.quietHoursEnd },
                            set: { value in setQuietHours(true, nil, value) }
                        ),
                        in: 0...23
                    )
                }
                if !applications.isEmpty {
                    // Named for whose apps these are. It used to be "Per-App
                    // Notifications", which says the shape and not the
                    // subject — and the row below is also per app, for the
                    // phone's apps, so the two read as the same thing twice.
                    DisclosureGroup("Per Watch App") {
                        ForEach(applications) { application in
                            Toggle(application.displayName, isOn: Binding(
                                get: { !notificationPreferences.mutedApplicationIDs.contains(application.id) },
                                set: { enabled in setNotificationsEnabled(enabled, application.id) }
                            ))
                        }
                    }
                }
            } footer: {
                Text("System notifications are delivered directly to a paired Pebble using Apple Notification Center Service. This switch controls notifications created by installed watch apps. Test notifications can be sent from each watch's detail page.")
            }
            Section {
                NavigationLink {
                    phoneAppsDestination()
                } label: {
                    LabeledContent("Phone App Notifications") {
                        Text("\(notificationSourceAppCount) apps")
                    }
                }
            } footer: {
                Text("Apps the watch has seen sending notifications, and what it does with each one.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Notifications"))
    }
}

#Preview("On, with apps installed") {
    NavigationStack {
        NotificationSettingsContent(
            companionNotificationsEnabled: true,
            notificationPreferences: NotificationDeliveryPreferences(),
            applications: PreviewSamples.watchApplications + PreviewSamples.watchfaces,
            notificationSourceAppCount: PreviewSamples.notificationApps.count,
            setCompanionNotificationsEnabled: { _ in },
            setQuietHours: { _, _, _ in },
            setNotificationsEnabled: { _, _ in },
            phoneAppsDestination: { EmptyView() }
        )
    }
}

#Preview("Quiet hours on, nothing installed") {
    NavigationStack {
        NotificationSettingsContent(
            companionNotificationsEnabled: false,
            notificationPreferences: NotificationDeliveryPreferences(
                quietHoursEnabled: true,
                quietHoursStart: 22,
                quietHoursEnd: 7
            ),
            applications: [],
            notificationSourceAppCount: 0,
            setCompanionNotificationsEnabled: { _ in },
            setQuietHours: { _, _, _ in },
            setNotificationsEnabled: { _, _ in },
            phoneAppsDestination: { EmptyView() }
        )
    }
}
