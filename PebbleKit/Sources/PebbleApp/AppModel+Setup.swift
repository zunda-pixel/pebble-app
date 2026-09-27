import Foundation

extension AppModel {
    /// Raises the system's own question for one permission, and nothing else.
    ///
    /// What the answer was is read back from `PhonePermissions` rather than
    /// returned: HealthKit will not say whether reading was allowed, so a
    /// returned Bool would be a guess for one of these and a fact for the rest.
    func requestPhonePermission(_ kind: PhonePermissionKind) async {
        switch kind {
        case .calendar:
            try? await calendarBridge.requestAccess()
        case .reminders:
            try? await remindersAppStore.requestAccess()
        case .location:
            // The alert is raised here; the answer arrives at the manager's
            // delegate, long after this returns.
            phoneLocationSource.requestAuthorization()
        case .health:
            #if os(iOS)
            try? await healthKitBridge.requestAuthorization()
            #endif
        }
    }
}
