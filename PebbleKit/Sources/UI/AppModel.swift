public import API
import Observation

@MainActor
@Observable
public final class AppModel {
    public private(set) var connectionState: PebbleConnectionState = .idle
    public private(set) var discoveredDevices: [DiscoveredPebble] = []

    private let client: any PebbleClient

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
        connectionState = .idle
    }
}
