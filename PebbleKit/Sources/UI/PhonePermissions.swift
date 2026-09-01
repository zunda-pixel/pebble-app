import CoreBluetooth
import CoreLocation
import EventKit
import Foundation
import MemberwiseInit
import SwiftUI
#if os(iOS)
import HealthKit
#endif

/// Where one of the phone's permissions stands.
public enum PhonePermissionState: Equatable, Sendable {
    case notDetermined
    case allowed
    /// Allowed, but only as far as this app needs it in one direction — a
    /// calendar it may add to but not read.
    case partly
    case denied
    /// Denied by someone other than the reader: a device policy, or a phone
    /// with no such hardware.
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

/// What the phone has been allowed to hand over.
///
/// Read rather than remembered: the reader can change any of these in the
/// system settings while the app is in the background, so it is asked again
/// whenever the screen comes back.
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

    /// Reading this does not ask: `CBManager.authorization` is a look at what
    /// has already been decided.
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
        // The app reads events to make pins of them, so write-only is not
        // enough for what it does.
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
        // Only the writing side can be read back. Apple deliberately gives no
        // way to ask whether reading was allowed, so that an app cannot tell
        // "no data" apart from "not allowed to look".
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
