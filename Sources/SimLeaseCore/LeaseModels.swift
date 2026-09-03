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

public struct LeaseLaneSummary: Codable, Equatable, Sendable {
    public let laneID: String
    public let slot: Int
    public let project: String
    public let threadID: String?
    public let threadTitle: String?
    public let udid: String
    public let deviceTypeName: String
    public let runtimeName: String
    public let lastActivityAt: Date
    public let recoveryRequired: Bool

    public init(
        laneID: String,
        slot: Int,
        project: String,
        threadID: String?,
        threadTitle: String?,
        udid: String,
        deviceTypeName: String,
        runtimeName: String,
        lastActivityAt: Date,
        recoveryRequired: Bool
    ) {
        self.laneID = laneID
        self.slot = slot
        self.project = project
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.udid = udid
        self.deviceTypeName = deviceTypeName
        self.runtimeName = runtimeName
        self.lastActivityAt = lastActivityAt
        self.recoveryRequired = recoveryRequired
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
    public let lanes: [LeaseLaneSummary]
    public let error: String?

    public init(
        state: State,
        owner: LeaseOwner?,
        waiters: [LeaseWaiter],
        lanes: [LeaseLaneSummary] = [],
        error: String?
    ) {
        self.state = state
        self.owner = owner
        self.waiters = waiters
        self.lanes = lanes
        self.error = error
    }
}

private enum SimLeaseDateCoder {
    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decode(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public extension JSONEncoder {
    static var simLease: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SimLeaseDateCoder.encode(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var simLease: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = SimLeaseDateCoder.decode(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date: \(string)"
            )
        }
        return decoder
    }
}
