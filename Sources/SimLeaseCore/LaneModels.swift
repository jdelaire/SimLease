import Foundation

public struct LaneConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let maxActive: Int

    public init(schemaVersion: Int = 1, maxActive: Int) {
        self.schemaVersion = schemaVersion
        self.maxActive = maxActive
    }
}

public struct LaneAcquireRequest: Codable, Equatable, Sendable {
    public let project: String
    public let deviceType: String
    public let runtime: String

    public init(project: String, deviceType: String, runtime: String) {
        self.project = project
        self.deviceType = deviceType
        self.runtime = runtime
    }
}

public struct LaneDescriptor: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let laneID: String
    public let slot: Int
    public let token: String
    public let project: String
    public let threadID: String?
    public let threadTitle: String?
    public let udid: String
    public let deviceTypeIdentifier: String
    public let deviceTypeName: String
    public let runtimeIdentifier: String
    public let runtimeName: String
    public let derivedDataPath: String
    public let acquiredAt: Date
    public let lastActivityAt: Date
    public let expiresAt: Date

    public init(
        schemaVersion: Int = 1,
        laneID: String,
        slot: Int,
        token: String,
        project: String,
        threadID: String?,
        threadTitle: String?,
        udid: String,
        deviceTypeIdentifier: String,
        deviceTypeName: String,
        runtimeIdentifier: String,
        runtimeName: String,
        derivedDataPath: String,
        acquiredAt: Date,
        lastActivityAt: Date,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.laneID = laneID
        self.slot = slot
        self.token = token
        self.project = project
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.udid = udid
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.deviceTypeName = deviceTypeName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.derivedDataPath = derivedDataPath
        self.acquiredAt = acquiredAt
        self.lastActivityAt = lastActivityAt
        self.expiresAt = expiresAt
    }
}

public struct LaneReservation: Codable, Equatable, Sendable {
    public let laneID: String
    public let slot: Int
    public let token: String
    public let project: String
    public let threadID: String?
    public let threadTitle: String?
    public let udid: String
    public let descriptorPath: String
    public let generation: Int
    public let acquiredAt: Date
    public let lastActivityAt: Date
    public let expiresAt: Date

    public init(
        laneID: String,
        slot: Int,
        token: String,
        project: String,
        threadID: String?,
        threadTitle: String?,
        udid: String,
        descriptorPath: String,
        generation: Int,
        acquiredAt: Date,
        lastActivityAt: Date,
        expiresAt: Date
    ) {
        self.laneID = laneID
        self.slot = slot
        self.token = token
        self.project = project
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.udid = udid
        self.descriptorPath = descriptorPath
        self.generation = generation
        self.acquiredAt = acquiredAt
        self.lastActivityAt = lastActivityAt
        self.expiresAt = expiresAt
    }
}

public enum ManagedSimulatorLifecycle: String, Codable, Equatable, Sendable {
    case reserved
    case idle
    case recoveryRequired
    case disposalPlanned
}

public struct ManagedSimulatorRecord: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let deviceTypeIdentifier: String
    public let deviceTypeName: String
    public let runtimeIdentifier: String
    public let runtimeName: String
    public let expectedDataPath: String
    public let createdAt: Date
    public var lifecycle: ManagedSimulatorLifecycle

    public init(
        udid: String,
        name: String,
        deviceTypeIdentifier: String,
        deviceTypeName: String,
        runtimeIdentifier: String,
        runtimeName: String,
        expectedDataPath: String,
        createdAt: Date,
        lifecycle: ManagedSimulatorLifecycle
    ) {
        self.udid = udid
        self.name = name
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.deviceTypeName = deviceTypeName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.expectedDataPath = expectedDataPath
        self.createdAt = createdAt
        self.lifecycle = lifecycle
    }
}

public struct ManagedSimulatorFingerprint: Codable, Equatable, Sendable {
    public let udid: String
    public let deviceTypeIdentifier: String
    public let runtimeIdentifier: String
    public let standardizedDataPath: String
    public let state: String

    public init(
        udid: String,
        deviceTypeIdentifier: String,
        runtimeIdentifier: String,
        standardizedDataPath: String,
        state: String
    ) {
        self.udid = udid
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
        self.standardizedDataPath = standardizedDataPath
        self.state = state
    }
}

public enum LaneAcquireState: String, Codable, Equatable, Sendable {
    case acquired
    case capacityFull
}

public struct LaneAcquireResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let state: LaneAcquireState
    public let lane: LaneDescriptor?
    public let environment: [String: String]
    public let xcodebuildArguments: [String]
    public let derivedDataPath: String?
    public let resultBundlePath: String?
    public let releaseCommand: [String]
    public let nextActions: [String]

    public init(
        schemaVersion: Int = 1,
        state: LaneAcquireState,
        lane: LaneDescriptor?,
        environment: [String: String],
        xcodebuildArguments: [String],
        derivedDataPath: String?,
        resultBundlePath: String?,
        releaseCommand: [String],
        nextActions: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.lane = lane
        self.environment = environment
        self.xcodebuildArguments = xcodebuildArguments
        self.derivedDataPath = derivedDataPath
        self.resultBundlePath = resultBundlePath
        self.releaseCommand = releaseCommand
        self.nextActions = nextActions
    }
}

public struct LaneStatusEntry: Codable, Equatable, Sendable {
    public let laneID: String
    public let slot: Int
    public let project: String
    public let threadID: String?
    public let threadTitle: String?
    public let udid: String
    public let runtimeName: String
    public let deviceTypeName: String
    public let lastActivityAt: Date
    public let expiresAt: Date
    public let isCommandActive: Bool
    public let recoveryRequired: Bool

    public init(
        laneID: String,
        slot: Int,
        project: String,
        threadID: String?,
        threadTitle: String?,
        udid: String,
        runtimeName: String,
        deviceTypeName: String,
        lastActivityAt: Date,
        expiresAt: Date,
        isCommandActive: Bool,
        recoveryRequired: Bool
    ) {
        self.laneID = laneID
        self.slot = slot
        self.project = project
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.udid = udid
        self.runtimeName = runtimeName
        self.deviceTypeName = deviceTypeName
        self.lastActivityAt = lastActivityAt
        self.expiresAt = expiresAt
        self.isCommandActive = isCommandActive
        self.recoveryRequired = recoveryRequired
    }
}

public struct LaneStatusReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configuration: LaneConfiguration
    public let reserved: [LaneStatusEntry]
    public let availableSlots: [Int]

    public init(
        schemaVersion: Int = 1,
        configuration: LaneConfiguration,
        reserved: [LaneStatusEntry],
        availableSlots: [Int]
    ) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.reserved = reserved
        self.availableSlots = availableSlots
    }
}

public struct LaneConfigurationReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configuration: LaneConfiguration
    public let reservationCount: Int

    public init(
        schemaVersion: Int = 1,
        configuration: LaneConfiguration,
        reservationCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.reservationCount = reservationCount
    }
}

public struct LaneReleaseResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let laneID: String
    public let udid: String
    public let state: String
    public let disposalPlanCommand: [String]

    public init(
        schemaVersion: Int = 1,
        laneID: String,
        udid: String,
        state: String,
        disposalPlanCommand: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.laneID = laneID
        self.udid = udid
        self.state = state
        self.disposalPlanCommand = disposalPlanCommand
    }
}

public struct LaneDisposalResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    public let udid: String
    public let deleted: Bool

    public init(
        schemaVersion: Int = 1,
        planID: String,
        udid: String,
        deleted: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.udid = udid
        self.deleted = deleted
    }
}

public enum LaneLifecyclePlanKind: String, Codable, Equatable, Sendable {
    case recovery
    case disposal
}

public struct LaneLifecyclePlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let kind: LaneLifecyclePlanKind
    public let createdAt: Date
    public let expiresAt: Date
    public let laneID: String?
    public let reservationGeneration: Int?
    public let reservationToken: String?
    public let reservationThreadID: String?
    public let lastActivityAt: Date?
    public let fingerprint: ManagedSimulatorFingerprint

    public init(
        schemaVersion: Int = 1,
        id: String,
        kind: LaneLifecyclePlanKind,
        createdAt: Date,
        expiresAt: Date,
        laneID: String?,
        reservationGeneration: Int?,
        reservationToken: String? = nil,
        reservationThreadID: String? = nil,
        lastActivityAt: Date?,
        fingerprint: ManagedSimulatorFingerprint
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.laneID = laneID
        self.reservationGeneration = reservationGeneration
        self.reservationToken = reservationToken
        self.reservationThreadID = reservationThreadID
        self.lastActivityAt = lastActivityAt
        self.fingerprint = fingerprint
    }
}

public enum LaneServiceError: Error, Equatable {
    case capacityFull(LaneStatusReport)
    case runtimeUnavailable(requested: String, available: [String])
    case deviceTypeUnavailable(requested: String, available: [String])
    case invalidLaneDescriptor(String)
    case laneOwnershipMismatch(laneID: String)
    case targetMismatch(expected: String, actual: String?)
    case derivedDataMismatch(expected: String, actual: String?)
    case globalMutationBusy
    case laneRecoveryTooRecent(expiresAt: Date)
    case unsupportedAXeTargeting
    case recoveryRequired(laneID: String)
    case metadataError(String)
}
