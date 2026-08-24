public import API
public import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    public private(set) var connectionState: PebbleConnectionState = .idle
    public private(set) var discoveredDevices: [DiscoveredPebble] = []
    public private(set) var watchApplications: [PebbleApplication] = []
    public private(set) var watchfaces: [PebbleApplication] = []
    public private(set) var isLoadingApplications = false
    public private(set) var applicationLibraryErrorMessage: String?

    private let client: any PebbleClient
    private let applicationLibrary: PebbleApplicationLibrary
    @ObservationIgnored private var connectionEventsTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedApplications = false

    public init(
        client: any PebbleClient,
        applicationLibrary: PebbleApplicationLibrary = PebbleApplicationLibrary()
    ) {
        self.client = client
        self.applicationLibrary = applicationLibrary
    }

    public var connectedDevice: PebbleDevice? {
        guard case .connected(let device) = connectionState else {
            return nil
        }
        return device
    }

    public func scan() async {
        connectionState = .scanning

        do {
            discoveredDevices = try await client.scan()
            connectionState = .idle
        } catch let error as PebbleConnectionError {
            connectionState = .failed(error)
        } catch {
            connectionState = .failed(.bluetoothUnavailable)
        }
    }

    public func connect(to device: DiscoveredPebble) async {
        connectionState = .connecting(deviceID: device.id)

        do {
            let connectedDevice = try await client.connect(to: device)
            connectionState = .connected(connectedDevice)
            observeConnectionEvents()
        } catch let error as PebbleConnectionError {
            connectionState = .failed(error)
        } catch {
            connectionState = .failed(.protocolNegotiationFailed)
        }
    }

    public func disconnect() async {
        guard let device = connectedDevice else {
            return
        }

        await client.disconnect(from: device)
        connectionEventsTask?.cancel()
        connectionEventsTask = nil
        connectionState = .idle
    }

    public func loadApplications() async {
        guard !hasLoadedApplications else {
            return
        }
        hasLoadedApplications = true
        isLoadingApplications = true
        defer { isLoadingApplications = false }
        do {
            updateApplications(try await applicationLibrary.applications())
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = error.localizedDescription
        }
    }

    public func removeApplication(id: UUID) async {
        do {
            updateApplications(try await applicationLibrary.remove(applicationID: id))
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = error.localizedDescription
        }
    }

    private func updateApplications(_ applications: [PebbleApplication]) {
        watchApplications = applications.filter { $0.kind == .watchapp }
        watchfaces = applications.filter { $0.kind == .watchface }
    }

    private func observeConnectionEvents() {
        connectionEventsTask?.cancel()
        connectionEventsTask = Task { [weak self, client] in
            for await event in client.events() {
                guard !Task.isCancelled else {
                    return
                }
                switch event {
                case .deviceUpdated(let device):
                    self?.connectionState = .connected(device)
                case .appFetchRequested:
                    try? await client.respondToAppFetch(with: .noData)
                case .transferProgress:
                    break
                case .reconnecting(let deviceID):
                    self?.connectionState = .reconnecting(deviceID: deviceID)
                case .disconnected(let error):
                    self?.connectionState = .failed(error)
                    return
                }
            }
        }
    }
}
