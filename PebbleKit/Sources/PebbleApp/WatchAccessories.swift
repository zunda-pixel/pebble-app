#if os(iOS)
import AccessoryNotifications
import AccessorySetupKit
internal import CoreBluetooth
import Defaults
import Foundation
import Observation
public import PebbleProtocol
import UIKit
#endif

/// Whether iOS forwards a watch's notifications to it through
/// AccessoryNotifications.
public enum NotificationForwarding: Equatable, Sendable {
    case on
    /// Forwarding is on for the apps the reader picked in Settings.
    case someApps
    case off
    /// The watch was paired before the app used the system's accessory setup,
    /// so iOS has nothing to forward to.
    case notSetUp
    /// iOS does not take the watch as one it can forward to: the extensions
    /// that carry notifications to it are not set up for it.
    case unsupportedAccessory
    /// iOS said this phone cannot take part.
    case unavailable
}

#if os(iOS)

/// The watches paired through AccessorySetupKit, and what iOS forwards to each.
///
/// On iOS a watch is found and paired through the system's picker rather than
/// by scanning: AccessoryNotifications forwards only to an `ASAccessory`, and a
/// central made before the session has migrated the watches already paired
/// makes the picker fail — so the radio waits for `offerMigration(of:)`.
@MainActor
@Observable
final class WatchAccessories {
    struct Accessory: Equatable, Sendable {
        var id: WatchID
        var name: String
    }

    private(set) var accessories: [Accessory] = []
    private(set) var forwarding: [WatchID: NotificationForwarding] = [:]

    enum PickerError: Error {
        case alreadyShowing
        case couldNotShow(String)
    }

    private static let pairingService = CBUUID(string: WatchAdvertisement.pairingServiceUUID)

    @ObservationIgnored private let session = ASAccessorySession()
    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var activated: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var picking: CheckedContinuation<[Accessory], any Error>?
    @ObservationIgnored private var presented: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var addedWhilePicking: [Accessory] = []

    /// Starts the session. Later calls return once the first has.
    func activate() async {
        if let activation {
            await activation.value
            return
        }
        let activation = Task { [weak self] in
            guard let self else { return }
            await withCheckedContinuation { continuation in
                self.activated = continuation
                self.session.activate(on: .main) { [weak self] event in
                    MainActor.assumeIsolated { self?.handle(event) }
                }
            }
        }
        self.activation = activation
        await activation.value
    }

    /// Offers the watches paired before the session to it, once per install,
    /// and returns as soon as the picker is up rather than when the reader is
    /// done with it: a central opened before then stops it appearing, and
    /// waiting for its dismissal held the whole radio back for as long as the
    /// reader left it open.
    ///
    /// Declined or not shown, the watch still connects as it did: the app keeps
    /// its Bluetooth permission. Only forwarding needs it migrated, and that
    /// section says so — offering again on every launch put the same picker in
    /// front of a reader who had already said no.
    func offerMigration(of saved: [SavedWatch]) async {
        await activate()
        guard !Defaults[.hasOfferedAccessoryMigration], presented == nil, picking == nil else { return }
        let items = saved
            .filter { watch in !accessories.contains { $0.id == watch.id } }
            .compactMap(Self.migrationItem)
        guard !items.isEmpty else { return }
        await withCheckedContinuation { continuation in
            presented = continuation
            Task { [weak self] in
                do {
                    _ = try await self?.pick(items)
                } catch {
                    self?.finishPresenting()
                }
            }
        }
    }

    /// Shows the system's picker for a new watch and returns the watches added
    /// through it.
    func choose() async throws -> [Accessory] {
        let item = ASPickerDisplayItem(
            name: "Pebble",
            productImage: UIImage(systemName: "applewatch") ?? UIImage(),
            descriptor: Self.descriptor()
        )
        return try await pick([item])
    }

    /// Takes the watch out of the system's accessories. Without this a
    /// forgotten watch stays paired to the app in Settings, and the picker will
    /// not offer it again.
    func forget(_ watchID: WatchID) async throws {
        guard let accessory = asAccessory(watchID) else { return }
        try await session.removeAccessory(accessory)
        forwarding[watchID] = nil
    }

    func refreshForwarding(_ watchID: WatchID) async {
        guard let accessory = asAccessory(watchID) else {
            await DiagnosticLog.shared.record(
                .warning,
                category: "forwarding",
                message: "\(watchID) is not among the \(session.accessories.count) accessories iOS lists for the app"
            )
            forwarding[watchID] = .notSetUp
            return
        }
        forwarding[watchID] = await Self.forwarding("status", watchID) {
            // Made per call: the centre is not Sendable, and one kept here
            // would have to cross from the main actor to be asked.
            try await AccessoryNotificationCenter().forwardingStatus(for: accessory)
        }
    }

    /// Asks iOS to forward to the watch. The system asks the reader; nothing
    /// here does.
    func requestForwarding(_ watchID: WatchID) async {
        guard let accessory = asAccessory(watchID) else {
            await DiagnosticLog.shared.record(
                .warning,
                category: "forwarding",
                message: "\(watchID) is not among the \(session.accessories.count) accessories iOS lists for the app"
            )
            forwarding[watchID] = .notSetUp
            return
        }
        forwarding[watchID] = await Self.forwarding("request", watchID) {
            try await AccessoryNotificationCenter().requestForwarding(for: accessory)
        }
    }

    func presentForwardingSettings(_ watchID: WatchID) async {
        guard let accessory = asAccessory(watchID) else { return }
        forwarding[watchID] = await Self.forwarding("settings", watchID) {
            try await AccessoryNotificationCenter().presentSettings(for: accessory)
        }
    }

    private func pick(_ items: [ASPickerDisplayItem]) async throws -> [Accessory] {
        guard picking == nil else { throw PickerError.alreadyShowing }
        return try await withCheckedThrowingContinuation { continuation in
            picking = continuation
            addedWhilePicking = []
            session.showPicker(for: items) { [weak self] error in
                guard let error else { return }
                MainActor.assumeIsolated {
                    self?.finishPicking(with: .failure(PickerError.couldNotShow(error.localizedDescription)))
                }
            }
        }
    }

    /// Both ways the picker ends — dismissed, or never shown — come through
    /// here, and only the first resumes the caller.
    private func finishPicking(with result: Result<[Accessory], any Error>) {
        finishPresenting()
        guard let picking else { return }
        self.picking = nil
        picking.resume(with: result)
    }

    /// The picker is up, or is never going to be: either lets the caller of
    /// `offerMigration` go on.
    private func finishPresenting() {
        guard let presented else { return }
        self.presented = nil
        presented.resume()
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            accessories = session.accessories.compactMap(Self.accessory)
            activated?.resume()
            activated = nil
        case .accessoryAdded:
            accessories = session.accessories.compactMap(Self.accessory)
            if let added = event.accessory.flatMap(Self.accessory) {
                addedWhilePicking.append(added)
            }
        case .accessoryChanged, .accessoryRemoved:
            accessories = session.accessories.compactMap(Self.accessory)
        case .pickerDidPresent:
            if presented != nil {
                Defaults[.hasOfferedAccessoryMigration] = true
            }
            finishPresenting()
        case .pickerDidDismiss:
            finishPicking(with: .success(addedWhilePicking))
        case .invalidated:
            // The session cannot be used again: a picker it had open will never
            // report its dismissal, and the radio must not wait on it for ever.
            activated?.resume()
            activated = nil
            finishPicking(with: .success(addedWhilePicking))
        default:
            break
        }
    }

    private func asAccessory(_ watchID: WatchID) -> ASAccessory? {
        session.accessories.first { $0.bluetoothIdentifier?.uuidString == watchID.rawValue }
    }

    private static func accessory(_ accessory: ASAccessory) -> Accessory? {
        accessory.bluetoothIdentifier.map {
            Accessory(id: WatchID($0.uuidString), name: accessory.displayName)
        }
    }

    /// Without `bluetoothPairingLE` the system only connects to the watch while
    /// adding it, and the bond is made afterwards by the app's own connection.
    /// iOS then refuses to forward notifications to it: `usernotificationsd`
    /// logs "Bluetooth not securely connected" and `requestForwarding` throws
    /// `unsupportedAccessory`.
    private static func descriptor() -> ASDiscoveryDescriptor {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = pairingService
        descriptor.supportedOptions = .bluetoothPairingLE
        return descriptor
    }

    private static func migrationItem(_ watch: SavedWatch) -> ASMigrationDisplayItem? {
        guard let identifier = UUID(uuidString: watch.id.rawValue) else { return nil }
        let item = ASMigrationDisplayItem(
            name: watch.name,
            productImage: UIImage(systemName: "applewatch") ?? UIImage(),
            descriptor: descriptor()
        )
        item.peripheralIdentifier = identifier
        return item
    }

    private static func forwarding(
        _ asked: String,
        _ watchID: WatchID,
        _ ask: () async throws -> ForwardingDecision
    ) async -> NotificationForwarding {
        do {
            let decision = try await ask()
            await DiagnosticLog.shared.record(
                category: "forwarding",
                message: "\(asked) for \(watchID): \(decision)"
            )
            return switch decision {
            case .allow: .on
            case .limited: .someApps
            default: .off
            }
        } catch {
            await DiagnosticLog.shared.record(
                .error,
                category: "forwarding",
                message: "\(asked) for \(watchID) failed: \(String(describing: error))"
            )
            return error as? AccessoryError == .unsupportedAccessory ? .unsupportedAccessory : .unavailable
        }
    }
}
#endif
