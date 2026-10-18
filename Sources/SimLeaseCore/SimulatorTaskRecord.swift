import Foundation

public enum SimulatorTaskError: Error, CustomStringConvertible {
    case unknownDevice(String)
    case unfinishedTask(String)
    case unverifiedProcess(Int32)
    case commandFailed(String)
    case commandTimedOut(String)

    public var description: String {
        switch self {
        case .unknownDevice(let id): "unknown simulator: \(id)"
        case .unfinishedTask(let detail): "unfinished simulator task: \(detail); run simlease recover"
        case .unverifiedProcess(let pid): "cannot verify ownership of process group \(pid)"
        case .commandFailed(let detail): detail
        case .commandTimedOut(let detail): "simulator command timed out: \(detail)"
        }
    }
}

public struct SimulatorTaskRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case starting
        case running
        case cleaning
        case quarantined
    }

    public let token: String
    public let owner: ProcessReference
    public let deviceIDs: [String]
    public let ownedDeviceIDs: [String]
    public var child: ProcessReference?
    public var phase: Phase
    public var failure: String?
    public var exitCode: Int32?

    public init(
        token: String, owner: ProcessReference, deviceIDs: [String],
        ownedDeviceIDs: [String], phase: Phase = .starting
    ) {
        self.token = token
        self.owner = owner
        self.deviceIDs = deviceIDs
        self.ownedDeviceIDs = ownedDeviceIDs
        self.phase = phase
    }
}

public struct SimulatorTaskStore: Sendable {
    public let paths: LeasePaths

    public init(paths: LeasePaths) { self.paths = paths }

    public func read() throws -> SimulatorTaskRecord? {
        guard FileManager.default.fileExists(atPath: paths.task.path) else { return nil }
        do {
            return try JSONDecoder().decode(SimulatorTaskRecord.self, from: Data(contentsOf: paths.task))
        } catch {
            throw MetadataStoreError.corruptFile(paths.task)
        }
    }

    public func write(_ record: SimulatorTaskRecord) throws {
        try JSONEncoder().encode(record).write(to: paths.task, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.task.path)
        let handle = try FileHandle(forWritingTo: paths.task)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: paths.task.path) else { return }
        try FileManager.default.removeItem(at: paths.task)
    }

    public func authorizesNestedCommand(environment: [String: String], pid: Int32) throws -> Bool {
        guard let token = environment["SIMLEASE_TOKEN"],
              let record = try read(), record.token == token,
              record.phase == .running,
              record.owner.isAncestor(of: pid),
              let owner = try MetadataStore(paths: paths).readOwner(),
              owner.pid == record.owner.pid
        else { return false }
        return true
    }

    public func validateNestedDevices(_ ids: [String]) throws {
        guard let record = try read(), Set(ids).isSubset(of: Set(record.deviceIDs)) else {
            throw SimulatorTaskError.commandFailed("declare every device on the outer simlease run or hold scope")
        }
    }
}
