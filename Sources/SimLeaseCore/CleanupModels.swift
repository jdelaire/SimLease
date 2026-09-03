import Foundation

public enum CleanupTargetKind: String, Codable, Equatable, Sendable {
    case device
    case runtime
    case filesystem
}

public enum CleanupCategory: String, Codable, Equatable, Sendable {
    case simulatorDevice
    case simulatorRuntime
    case temporaryDerivedData
    case previews
    case derivedData
    case swiftBuild
    case resultBundle
    case archive
    case deviceSupport
}

public enum CleanupRiskTier: String, Codable, Equatable, Sendable {
    case rebuildable
    case guarded
}

public enum CleanupAction: String, Codable, Equatable, Sendable {
    case deletePermanently
    case moveToTrash
}

public enum CleanupFingerprint: Codable, Equatable, Sendable {
    case filesystem(path: String, sizeBytes: Int64, modifiedAt: Date)
}

public struct CleanupTarget: Codable, Equatable, Sendable {
    public let kind: CleanupTargetKind
    public let identifier: String
    public let name: String
    public let detail: String
    public let category: CleanupCategory
    public let riskTier: CleanupRiskTier
    public let action: CleanupAction
    public let path: String?
    public let runtimeIdentifier: String
    public let lastUsedAt: Date?
    public let sizeBytes: Int64?
    public let fingerprint: CleanupFingerprint?
    public let selectedByDefault: Bool

    public init(
        kind: CleanupTargetKind,
        identifier: String,
        name: String,
        detail: String = "",
        category: CleanupCategory? = nil,
        riskTier: CleanupRiskTier = .rebuildable,
        action: CleanupAction = .deletePermanently,
        path: String? = nil,
        runtimeIdentifier: String,
        lastUsedAt: Date?,
        sizeBytes: Int64?,
        fingerprint: CleanupFingerprint? = nil,
        selectedByDefault: Bool = true
    ) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
        self.detail = detail
        self.category = category ?? {
            switch kind {
            case .device: .simulatorDevice
            case .runtime: .simulatorRuntime
            case .filesystem: .derivedData
            }
        }()
        self.riskTier = riskTier
        self.action = action
        self.path = path
        self.runtimeIdentifier = runtimeIdentifier
        self.lastUsedAt = lastUsedAt
        self.sizeBytes = sizeBytes
        self.fingerprint = fingerprint
        self.selectedByDefault = selectedByDefault
    }
}

public enum CleanupProtectionReason: String, Codable, Equatable, Sendable {
    case activeTests
    case activePath
    case booted
    case bootedRuntime
    case invalidDataPath
    case missingIdentifier
    case missingLastUsedAt
    case notOldEnough
    case notOutdated
    case changedSinceReview
    case invalidCleanupPath
    case simulatorLeased
    case managedLane
}

public struct LaneProtectionSnapshot: Equatable, Sendable {
    public let reservedDeviceIDs: Set<String>
    public let activeDerivedDataPaths: Set<String>
    public let activeResultBundlePaths: Set<String>

    public init(
        reservedDeviceIDs: Set<String>,
        activeDerivedDataPaths: Set<String>,
        activeResultBundlePaths: Set<String>
    ) {
        self.reservedDeviceIDs = reservedDeviceIDs
        self.activeDerivedDataPaths = activeDerivedDataPaths
        self.activeResultBundlePaths = activeResultBundlePaths
    }

    public static let empty = LaneProtectionSnapshot(
        reservedDeviceIDs: [],
        activeDerivedDataPaths: [],
        activeResultBundlePaths: []
    )

    public func protects(path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL.pathComponents
        return activeDerivedDataPaths
            .union(activeResultBundlePaths)
            .contains { activePath in
                let active = URL(fileURLWithPath: activePath)
                    .standardizedFileURL.pathComponents
                return Self.isPrefix(candidate, of: active)
                    || Self.isPrefix(active, of: candidate)
            }
    }

    private static func isPrefix(_ prefix: [String], of value: [String]) -> Bool {
        prefix.count <= value.count
            && zip(prefix, value).allSatisfy { $0 == $1 }
    }
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
    public let storage: [CleanupTarget]
    public let protected: [ProtectedCleanupTarget]
    public let deferred: [CleanupCategory]
    public let estimatedBytes: Int64
    public let availableBytesBefore: Int64?

    public init(
        id: String,
        createdAt: Date,
        expiresAt: Date,
        devices: [CleanupTarget],
        runtimes: [CleanupTarget],
        storage: [CleanupTarget] = [],
        protected: [ProtectedCleanupTarget],
        deferred: [CleanupCategory] = [],
        estimatedBytes: Int64,
        availableBytesBefore: Int64?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.devices = devices
        self.runtimes = runtimes
        self.storage = storage
        self.protected = protected
        self.deferred = deferred
        self.estimatedBytes = estimatedBytes
        self.availableBytesBefore = availableBytesBefore
    }

    public var targets: [CleanupTarget] {
        devices + runtimes + storage
    }

    public var defaultSelectedTargetIDs: Set<String> {
        Set(targets.filter(\.selectedByDefault).map(\.identifier))
    }
}

public struct CleanupReview: Codable, Equatable, Sendable {
    public let plan: CleanupPlan?
    public let protected: [ProtectedCleanupTarget]
    public let deferred: [CleanupCategory]
    public let estimatedBytes: Int64

    public init(
        plan: CleanupPlan?,
        protected: [ProtectedCleanupTarget],
        deferred: [CleanupCategory] = [],
        estimatedBytes: Int64
    ) {
        self.plan = plan
        self.protected = protected
        self.deferred = deferred
        self.estimatedBytes = estimatedBytes
    }
}

public enum CleanupItemOutcome: String, Codable, Equatable, Sendable {
    case deleted
    case movedToTrash
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
        items.contains {
            $0.outcome != .deleted && $0.outcome != .movedToTrash
        }
    }
}
