import Foundation

public enum LeaseSource: String, Codable, Sendable {
    case codex
    case terminal
    case manualXcode
}

public struct LeaseOwner: Codable, Equatable, Sendable {
    public let pid: Int32
    public let acquiredAt: Date
    public let cwd: String
    public let project: String
    public let command: [String]
    public let source: LeaseSource
    public let threadID: String?
    public let threadTitle: String?

    public init(
        pid: Int32,
        acquiredAt: Date,
        cwd: String,
        project: String,
        command: [String],
        source: LeaseSource,
        threadID: String?,
        threadTitle: String?
    ) {
        self.pid = pid
        self.acquiredAt = acquiredAt
        self.cwd = cwd
        self.project = project
        self.command = command
        self.source = source
        self.threadID = threadID
        self.threadTitle = threadTitle
    }
}

public struct LeaseWaiter: Codable, Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let waitingSince: Date
    public let cwd: String
    public let project: String
    public let command: [String]
    public let source: LeaseSource
    public let threadID: String?
    public let threadTitle: String?

    public init(
        id: String,
        pid: Int32,
        waitingSince: Date,
        cwd: String,
        project: String,
        command: [String],
        source: LeaseSource,
        threadID: String?,
        threadTitle: String?
    ) {
        self.id = id
        self.pid = pid
        self.waitingSince = waitingSince
        self.cwd = cwd
        self.project = project
        self.command = command
        self.source = source
        self.threadID = threadID
        self.threadTitle = threadTitle
    }
}

public struct LeaseStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case free
        case leased
        case metadataError
    }

    public let state: State
    public let owner: LeaseOwner?
    public let waiters: [LeaseWaiter]
    public let error: String?

    public init(
        state: State,
        owner: LeaseOwner?,
        waiters: [LeaseWaiter],
        error: String?
    ) {
        self.state = state
        self.owner = owner
        self.waiters = waiters
        self.error = error
    }
}

public extension JSONEncoder {
    static var simLease: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var simLease: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
