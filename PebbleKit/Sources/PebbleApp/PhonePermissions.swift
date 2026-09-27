import CoreBluetooth
import CoreLocation
import EventKit
import Foundation
import MemberwiseInit
import SwiftUI
#if os(iOS)
import HealthKit
#endif

public enum PhonePermissionState: Equatable, Sendable {
    case notDetermined
    case allowed
    /// Allowed in one direction only — a calendar this app may add to but not
    /// read.
    case partly
    case denied
    /// Denied by a policy the reader cannot change — parental controls or
    /// an MDM profile — or a phone with no such hardware.
    case restricted
    case unavailable
    /// Apple provides no way to read this one back.
    case unknown

    var title: LocalizedStringKey {
        switch self {
        case .notDetermined: "Not Asked Yet"
        case .allowed: "Allowed"
        case .partly: "Partly Allowed"
        case .denied: "Not Allowed"
        case .restricted: "Restricted"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }

    var isSettled: Bool { self == .allowed }
}

/// One thing this app has to be allowed to read, as something the setup flow can
/// hold and ask for.
///
/// Bluetooth is not among them: a watch cannot have connected without it.
public enum PhonePermissionKind: String, CaseIterable, Identifiable, Sendable {
    case calendar
    case reminders
    case location
    case health

    public var id: Self { self }

    /// In the order setup asks for them, leaving out what this platform has no
    /// answer for.
    public static var asked: [Self] {
        #if os(iOS)
        [.calendar, .reminders, .location, .health]
        #else
        [.calendar, .reminders, .location]
        #endif
    }

    var title: LocalizedStringKey {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .location: "Location"
        case .health: "Health"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .calendar: "Events become timeline pins on the watch, so the day ahead is on your wrist."
        case .reminders: "Reminders are sent to the watch's own reminder app, which buzzes when one is due."
        case .location: "Weather for where the phone is, rather than a place typed in by hand."
        case .health: "Steps and sleep the watch recorded are written to Health, and what the phone recorded is shown next to them."
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .location: "location"
        case .health: "heart"
        }
    }

    func state(in permissions: PhonePermissions) -> PhonePermissionState {
        switch self {
        case .calendar: permissions.calendar
        case .reminders: permissions.reminders
        case .location: permissions.location
        case .health: permissions.health
        }
    }
}

@MemberwiseInit(.public)
public struct PhonePermissions: Equatable, Sendable {
    public var bluetooth: PhonePermissionState = .notDetermined
    public var calendar: PhonePermissionState = .notDetermined
    public var reminders: PhonePermissionState = .notDetermined
    public var location: PhonePermissionState = .notDetermined
    public var health: PhonePermissionState = .notDetermined

    @MainActor
    public static func current() -> PhonePermissions {
        PhonePermissions(
            bluetooth: bluetoothState(),
            calendar: eventKitState(for: .event),
            reminders: eventKitState(for: .reminder),
            location: locationState(),
            health: healthState()
        )
    }

    // `CBManager.authorization` is a look at what has already been decided, not
    // a request.
    private static func bluetoothState() -> PhonePermissionState {
        switch CBManager.authorization {
        case .notDetermined: .notDetermined
        case .allowedAlways: .allowed
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func eventKitState(for entity: EKEntityType) -> PhonePermissionState {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .notDetermined: .notDetermined
        case .fullAccess: .allowed
        // The app reads events to make pins of them, so write-only is not enough.
        case .writeOnly: .partly
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    @MainActor
    private static func locationState() -> PhonePermissionState {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorizedAlways: .allowed
        #if os(iOS) || os(visionOS)
        case .authorizedWhenInUse: .allowed
        #endif
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    private static func healthState() -> PhonePermissionState {
        #if os(iOS)
        guard HKHealthStore.isHealthDataAvailable(),
              let steps = HKQuantityType.quantityType(forIdentifier: .stepCount)
        else { return .unavailable }
        // Only the writing side can be read back: Apple deliberately gives no way to
        // tell "no data" apart from "not allowed".
        switch HKHealthStore().authorizationStatus(for: steps) {
        case .notDetermined: return .notDetermined
        case .sharingAuthorized: return .allowed
        case .sharingDenied: return .denied
        @unknown default: return .unknown
        }
        #else
        return .unavailable
        #endif
    }
}

/// The system's own privacy settings, which is the only place a refusal can be
/// taken back: asking again after one does nothing at all.
@MainActor
func openPrivacySettings() {
#if os(macOS)
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
    NSWorkspace.shared.open(url)
#elseif os(iOS) || os(visionOS)
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
#endif
}
