import Foundation

public enum CleanupTargetKind: String, Codable, Equatable, Sendable {
    case device
    case runtime
}

public struct CleanupTarget: Codable, Equatable, Sendable {
    public let kind: CleanupTargetKind
    public let identifier: String
    public let name: String
    public let runtimeIdentifier: String
    public let lastUsedAt: Date?
    public let sizeBytes: Int64?

    public init(
        kind: CleanupTargetKind,
        identifier: String,
        name: String,
        runtimeIdentifier: String,
        lastUsedAt: Date?,
        sizeBytes: Int64?
    ) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.lastUsedAt = lastUsedAt
        self.sizeBytes = sizeBytes
    }
}

public enum CleanupProtectionReason: String, Codable, Equatable, Sendable {
    case activeTests
    case booted
    case bootedRuntime
    case invalidDataPath
    case missingIdentifier
    case missingLastUsedAt
    case notOldEnough
    case notOutdated
}

public struct ProtectedCleanupTarget: Codable, Equatable, Sendable {
    public let target: CleanupTarget
    public let reason: CleanupProtectionReason
    public let explanation: String

    public init(
        target: CleanupTarget,
        reason: CleanupProtectionReason,
        explanation: String
    ) {
        self.target = target
        self.reason = reason
        self.explanation = explanation
    }
}

public struct CleanupPlan: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let expiresAt: Date
    public let devices: [CleanupTarget]
    public let runtimes: [CleanupTarget]
    public let protected: [ProtectedCleanupTarget]
    public let estimatedBytes: Int64
    public let availableBytesBefore: Int64?

    public init(
        id: String,
        createdAt: Date,
        expiresAt: Date,
        devices: [CleanupTarget],
        runtimes: [CleanupTarget],
        protected: [ProtectedCleanupTarget],
        estimatedBytes: Int64,
        availableBytesBefore: Int64?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.devices = devices
        self.runtimes = runtimes
        self.protected = protected
        self.estimatedBytes = estimatedBytes
        self.availableBytesBefore = availableBytesBefore
    }
}

public struct CleanupReview: Codable, Equatable, Sendable {
    public let plan: CleanupPlan?
    public let protected: [ProtectedCleanupTarget]
    public let estimatedBytes: Int64

    public init(
        plan: CleanupPlan?,
        protected: [ProtectedCleanupTarget],
        estimatedBytes: Int64
    ) {
        self.plan = plan
        self.protected = protected
        self.estimatedBytes = estimatedBytes
    }
}

public enum CleanupItemOutcome: String, Codable, Equatable, Sendable {
    case deleted
    case skipped
    case failed
}

public struct CleanupItemResult: Codable, Equatable, Sendable {
    public let target: CleanupTarget
    public let outcome: CleanupItemOutcome
    public let message: String

    public init(
        target: CleanupTarget,
        outcome: CleanupItemOutcome,
        message: String
    ) {
        self.target = target
        self.outcome = outcome
        self.message = message
    }
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public let planID: String
    public let items: [CleanupItemResult]
    public let estimatedBytes: Int64
    public let availableBytesBefore: Int64?
    public let availableBytesAfter: Int64?

    public init(
        planID: String,
        items: [CleanupItemResult],
        estimatedBytes: Int64,
        availableBytesBefore: Int64?,
        availableBytesAfter: Int64?
    ) {
        self.planID = planID
        self.items = items
        self.estimatedBytes = estimatedBytes
        self.availableBytesBefore = availableBytesBefore
        self.availableBytesAfter = availableBytesAfter
    }

    public var isPartial: Bool {
        items.contains { $0.outcome != .deleted }
    }
}
