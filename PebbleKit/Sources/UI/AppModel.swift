public import API
import Observation

@MainActor
@Observable
public final class AppModel {
    public private(set) var connectionState: PebbleConnectionState = .idle
    public private(set) var discoveredDevices: [DiscoveredPebble] = []

    private let client: any PebbleClient
    @ObservationIgnored private var connectionEventsTask: Task<Void, Never>?

    public init(client: any PebbleClient) {
        self.client = client
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
