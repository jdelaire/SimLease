import Foundation

public struct SimulatorActivity: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case unmanaged
        case reservedNative
        case targetUnknown
    }

    public let process: ProcessReference
    public let tool: String
    public let kind: Kind
    public let deviceIDs: [String]

    public var id: String { "\(process.pid)-\(process.startMicroseconds)" }
}

public struct SimulatorActivityReport: Codable, Equatable, Sendable {
    public let activities: [SimulatorActivity]
    public let uninspectedProcessCount: Int
    public let error: String?
    public let nativeClients: [SimulatorNativeClient]?

    public var isIncomplete: Bool { error != nil || uninspectedProcessCount > 0 }

    public init(activities: [SimulatorActivity] = [], uninspectedProcessCount: Int = 0, error: String? = nil, nativeClients: [SimulatorNativeClient] = []) {
        self.activities = activities
        self.uninspectedProcessCount = uninspectedProcessCount
        self.error = error
        self.nativeClients = nativeClients.isEmpty ? nil : nativeClients
    }
}

public struct SimulatorNativeClient: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case deviceHub
        case agentDeviceDaemon
    }

    public let process: ProcessReference
    public let role: Role
    public let bound: Bool
}

struct SimulatorProcessSnapshot: Sendable {
    let process: ProcessReference
    let parentPID: Int32
    let executable: String
    let arguments: [String]
}

protocol SimulatorProcessReading: Sendable {
    func references() throws -> SimulatorProcessInventory
    func details(for reference: ProcessReference) throws -> SimulatorProcessSnapshot
    func current(pid: Int32) -> ProcessReference?
    func hasExited(pid: Int32) -> Bool
}

struct SimulatorProcessInventory: Sendable {
    let references: [ProcessReference]
    var uninspectedProcessCount = 0
}
