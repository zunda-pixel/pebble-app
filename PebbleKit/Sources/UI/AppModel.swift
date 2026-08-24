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
    public private(set) var isImportingApplication = false
    public private(set) var applicationLibraryErrorMessage: String?
    public private(set) var installingApplicationID: UUID?
    public private(set) var installingApplicationName: String?
    public private(set) var installationProgress: PutBytesTransferProgress?

    private let client: any PebbleClient
    private let applicationLibrary: PebbleApplicationLibrary
    @ObservationIgnored private var connectionEventsTask: Task<Void, Never>?
    @ObservationIgnored private var appFetchTask: Task<Void, Never>?
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
        appFetchTask?.cancel()
        appFetchTask = nil
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
            if connectedDevice != nil {
                try await client.unregisterApplication(applicationID: id)
            }
            updateApplications(try await applicationLibrary.remove(applicationID: id))
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = error.localizedDescription
        }
    }

    public func importApplication(from url: URL) async {
        isImportingApplication = true
        defer { isImportingApplication = false }
        let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            updateApplications(try await applicationLibrary.importPackage(from: url))
            hasLoadedApplications = true
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = error.localizedDescription
        }
    }

    public func reorderApplications(
        kind: PebbleApplicationKind,
        fromOffsets: IndexSet,
        toOffset: Int
    ) async {
        var selectedApplications = kind == .watchapp ? watchApplications : watchfaces
        guard move(&selectedApplications, fromOffsets: fromOffsets, toOffset: toOffset) else {
            return
        }
        let orderedApplications = kind == .watchapp
            ? selectedApplications + watchfaces
            : watchApplications + selectedApplications

        do {
            let applications = try await applicationLibrary.reorder(
                applicationIDs: orderedApplications.map(\.id)
            )
            updateApplications(applications)
            if connectedDevice != nil {
                try await client.reorderApplications(applications.map(\.id))
            }
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = error.localizedDescription
        }
    }

    private func move(
        _ applications: inout [PebbleApplication],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> Bool {
        guard !fromOffsets.isEmpty,
              fromOffsets.allSatisfy(applications.indices.contains),
              (0...applications.count).contains(toOffset) else {
            return false
        }
        let movingApplications = fromOffsets.map { applications[$0] }
        applications = applications.enumerated().compactMap { index, application in
            fromOffsets.contains(index) ? nil : application
        }
        let removedBeforeDestination = fromOffsets.count { $0 < toOffset }
        let insertionIndex = toOffset - removedBeforeDestination
        applications.insert(contentsOf: movingApplications, at: insertionIndex)
        return true
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
                case .appFetchRequested(let request):
                    self?.beginHandlingAppFetchRequest(request)
                case .transferProgress(let progress):
                    self?.installationProgress = progress
                case .reconnecting(let deviceID):
                    self?.connectionState = .reconnecting(deviceID: deviceID)
                case .disconnected(let error):
                    self?.connectionState = .failed(error)
                    return
                }
            }
        }
    }

    private func beginHandlingAppFetchRequest(_ request: AppFetchRequest) {
        guard appFetchTask == nil else {
            Task { try? await client.respondToAppFetch(with: .busy) }
            return
        }
        appFetchTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.handleAppFetchRequest(request)
            self.appFetchTask = nil
        }
    }

    private func handleAppFetchRequest(_ request: AppFetchRequest) async {
        guard let connectedDevice,
              let packageURL = await applicationLibrary.storedPackageURL(
                applicationID: request.applicationID
              ) else {
            try? await client.respondToAppFetch(with: .noData)
            return
        }

        installingApplicationID = request.applicationID
        installingApplicationName = (watchApplications + watchfaces)
            .first { $0.id == request.applicationID }?
            .displayName
        installationProgress = PutBytesTransferProgress(bytesSent: 0, totalBytes: 0)
        defer {
            installingApplicationID = nil
            installingApplicationName = nil
            installationProgress = nil
        }

        do {
            let model = connectedDevice.model
            let package = try await Task.detached(priority: .userInitiated) {
                try PBWPackageImporter.load(from: packageURL, for: model)
            }.value
            guard package.application.id == request.applicationID else {
                try await client.respondToAppFetch(with: .invalidApplicationID)
                return
            }

            try await client.respondToAppFetch(with: .start)
            for object in package.objects {
                try await client.installApplicationObject(
                    [UInt8](object.data),
                    objectType: object.installationObject.objectType,
                    appBankID: request.appBankID
                )
            }
            try await client.registerApplication(package.appMetadata)
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = error.localizedDescription
            try? await client.respondToAppFetch(with: .noData)
        }
    }
}
