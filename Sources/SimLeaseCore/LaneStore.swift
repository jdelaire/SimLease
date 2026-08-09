import Darwin
import Foundation

public struct LanePersistentState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var configuration: LaneConfiguration
    public var reservations: [LaneReservation]
    public var managedDevices: [ManagedSimulatorRecord]

    public init(
        schemaVersion: Int = 1,
        configuration: LaneConfiguration,
        reservations: [LaneReservation],
        managedDevices: [ManagedSimulatorRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.reservations = reservations
        self.managedDevices = managedDevices
    }

    public static let empty = LanePersistentState(
        configuration: LaneConfiguration(maxActive: 2),
        reservations: [],
        managedDevices: []
    )
}

public enum LaneStoreError: Error, Equatable {
    case corruptFile(URL)
    case invalidState(String)
    case invalidDescriptorPath(URL)
    case invalidDescriptorID
    case systemCall(String, Int32)
}

public protocol LaneStoring: Sendable {
    func readState() throws -> LanePersistentState
    func writeState(_ state: LanePersistentState) throws
    func writeDescriptor(_ descriptor: LaneDescriptor) throws -> URL
    func readDescriptor(at url: URL) throws -> LaneDescriptor
    func removeDescriptor(at url: URL) throws
}

public final class LaneStore: LaneStoring, @unchecked Sendable {
    private let paths: LeasePaths
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(paths: LeasePaths, fileManager: FileManager = .default) throws {
        self.paths = paths
        self.fileManager = fileManager
        try createPrivateDirectory(paths.root)
        try createPrivateDirectory(paths.laneRoot)
        try createPrivateDirectory(paths.laneDescriptors)
        try createPrivateDirectory(paths.lanePlans)
        try createPrivateDirectory(paths.laneDerivedData)
        try createPrivateDirectory(paths.laneResultBundles)
        try createPrivateDirectory(
            paths.laneCommandLock(slot: 1).deletingLastPathComponent()
        )
    }

    public func readState() throws -> LanePersistentState {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: paths.laneState.path) else {
            return .empty
        }
        do {
            let state = try JSONDecoder.simLease.decode(
                LanePersistentState.self,
                from: Data(contentsOf: paths.laneState)
            )
            try validate(state)
            return state
        } catch let error as LaneStoreError {
            throw error
        } catch {
            throw LaneStoreError.corruptFile(paths.laneState)
        }
    }

    public func writeState(_ state: LanePersistentState) throws {
        try validate(state)
        let data = try JSONEncoder.simLease.encode(state)
        lock.lock()
        defer { lock.unlock() }
        try atomicWrite(data, to: paths.laneState)
    }

    public func writeDescriptor(_ descriptor: LaneDescriptor) throws -> URL {
        guard Self.validIdentifier(descriptor.laneID),
              Self.validIdentifier(descriptor.token)
        else {
            throw LaneStoreError.invalidDescriptorID
        }
        let destination = paths.laneDescriptors.appendingPathComponent(
            "\(descriptor.laneID).json"
        )
        let data = try JSONEncoder.simLease.encode(descriptor)
        lock.lock()
        defer { lock.unlock() }
        try atomicWrite(data, to: destination)
        return destination
    }

    public func readDescriptor(at url: URL) throws -> LaneDescriptor {
        let contained = try containedDescriptorURL(url)
        do {
            return try JSONDecoder.simLease.decode(
                LaneDescriptor.self,
                from: Data(contentsOf: contained)
            )
        } catch {
            throw LaneStoreError.corruptFile(contained)
        }
    }

    public func removeDescriptor(at url: URL) throws {
        let contained = try containedDescriptorURL(url)
        do {
            try fileManager.removeItem(at: contained)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private func validate(_ state: LanePersistentState) throws {
        guard state.schemaVersion == 1,
              state.configuration.schemaVersion == 1,
              state.configuration.maxActive > 0
        else {
            throw LaneStoreError.invalidState("unsupported schema or capacity")
        }
        guard Self.unique(state.reservations.map(\.laneID)),
              Self.unique(state.reservations.map(\.slot)),
              Self.unique(state.reservations.map(\.token)),
              Self.unique(state.reservations.map(\.udid)),
              state.reservations.allSatisfy({ $0.slot > 0 }),
              Self.unique(state.managedDevices.map(\.udid)),
              Self.unique(state.managedDevices.map {
                  URL(fileURLWithPath: $0.expectedDataPath).standardizedFileURL.path
              })
        else {
            throw LaneStoreError.invalidState("duplicate or invalid identity")
        }
        let managedIDs = Set(state.managedDevices.map(\.udid))
        guard state.reservations.allSatisfy({ managedIDs.contains($0.udid) }) else {
            throw LaneStoreError.invalidState("reservation references unmanaged device")
        }
    }

    private func containedDescriptorURL(_ url: URL) throws -> URL {
        let root = paths.laneDescriptors.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == root,
              candidate.pathExtension == "json"
        else {
            throw LaneStoreError.invalidDescriptorPath(url)
        }
        return candidate
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw LaneStoreError.systemCall("open", errno)
        }
        var failure: LaneStoreError?
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count >= 0 else {
                    failure = .systemCall("write", errno)
                    return
                }
                offset += count
            }
        }
        if failure == nil, fsync(descriptor) != 0 {
            failure = .systemCall("fsync", errno)
        }
        if close(descriptor) != 0, failure == nil {
            failure = .systemCall("close", errno)
        }
        if let failure {
            try? fileManager.removeItem(at: temporary)
            throw failure
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw LaneStoreError.systemCall("rename", code)
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-_")
            ).contains($0)
        }
    }

    private static func unique<Value: Hashable>(_ values: [Value]) -> Bool {
        Set(values).count == values.count
    }
}
