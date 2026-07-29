import Foundation

public struct CleanupPlanner: Sendable {
    public let devicesRoot: URL
    public let staleAge: TimeInterval
    public let planLifetime: TimeInterval

    public init(
        devicesRoot: URL,
        staleAge: TimeInterval = 30 * 24 * 60 * 60,
        planLifetime: TimeInterval = 10 * 60
    ) {
        self.devicesRoot = devicesRoot.standardizedFileURL
        self.staleAge = staleAge
        self.planLifetime = planLifetime
    }

    public func makeReview(
        inventory: CleanupInventory,
        now: Date,
        id: String
    ) -> CleanupReview {
        var devices = [CleanupTarget]()
        var runtimes = [CleanupTarget]()
        var protectedDevices = [ProtectedCleanupTarget]()
        var protectedRuntimes = [ProtectedCleanupTarget]()
        let staleBoundary = now.addingTimeInterval(-staleAge)
        let bootedRuntimeIDs = Set(
            inventory.devices
                .filter { $0.state != "Shutdown" }
                .map(\.runtimeIdentifier)
        )

        for record in inventory.devices {
            let target = CleanupTarget(
                kind: .device,
                identifier: record.identifier,
                name: record.name,
                runtimeIdentifier: record.runtimeIdentifier,
                lastUsedAt: record.lastUsedAt,
                sizeBytes: record.sizeBytes
            )
            if let protection = deviceProtection(
                record,
                target: target,
                inventory: inventory,
                staleBoundary: staleBoundary
            ) {
                protectedDevices.append(protection)
            } else {
                devices.append(target)
            }
        }

        let sortedRuntimeRecords = inventory.runtimes.sorted {
            if $0.runtimeIdentifier != $1.runtimeIdentifier {
                return $0.runtimeIdentifier < $1.runtimeIdentifier
            }
            if $0.build != $1.build { return $0.build < $1.build }
            return $0.identifier < $1.identifier
        }
        for record in sortedRuntimeRecords {
            let target = CleanupTarget(
                kind: .runtime,
                identifier: record.identifier,
                name: record.name,
                runtimeIdentifier: record.runtimeIdentifier,
                lastUsedAt: nil,
                sizeBytes: record.sizeBytes
            )
            if let protection = runtimeProtection(
                record,
                target: target,
                inventory: inventory,
                bootedRuntimeIDs: bootedRuntimeIDs
            ) {
                protectedRuntimes.append(protection)
            } else {
                runtimes.append(target)
            }
        }

        devices.sort(by: deviceOrder)
        protectedDevices.sort { deviceOrder($0.target, $1.target) }
        let protected = protectedDevices + protectedRuntimes
        let estimatedBytes = (devices + runtimes).reduce(Int64(0)) {
            $0 + ($1.sizeBytes ?? 0)
        }

        guard !devices.isEmpty || !runtimes.isEmpty else {
            return CleanupReview(
                plan: nil,
                protected: protected,
                estimatedBytes: 0
            )
        }

        let plan = CleanupPlan(
            id: id,
            createdAt: now,
            expiresAt: now.addingTimeInterval(planLifetime),
            devices: devices,
            runtimes: runtimes,
            protected: protected,
            estimatedBytes: estimatedBytes,
            availableBytesBefore: inventory.availableBytes
        )
        return CleanupReview(
            plan: plan,
            protected: protected,
            estimatedBytes: estimatedBytes
        )
    }

    public func makeReview(
        inventory: CleanupInventory?,
        storage: XcodeStorageInventory,
        deferred: [CleanupCategory],
        now: Date,
        id: String
    ) -> CleanupReview {
        let simulatorReview = inventory.map {
            makeReview(inventory: $0, now: now, id: id)
        }
        let devices = simulatorReview?.plan?.devices ?? []
        let runtimes = simulatorReview?.plan?.runtimes ?? []
        let protected = (simulatorReview?.protected ?? []) + storage.protected
        let targets = devices + runtimes + storage.targets
        let estimatedBytes = targets.reduce(Int64(0)) {
            $0 + ($1.sizeBytes ?? 0)
        }

        guard !targets.isEmpty else {
            return CleanupReview(
                plan: nil,
                protected: protected,
                deferred: deferred,
                estimatedBytes: 0
            )
        }

        let plan = CleanupPlan(
            id: id,
            createdAt: now,
            expiresAt: now.addingTimeInterval(planLifetime),
            devices: devices,
            runtimes: runtimes,
            storage: storage.targets,
            protected: protected,
            deferred: deferred,
            estimatedBytes: estimatedBytes,
            availableBytesBefore: inventory?.availableBytes
        )
        return CleanupReview(
            plan: plan,
            protected: protected,
            deferred: deferred,
            estimatedBytes: estimatedBytes
        )
    }

    private func deviceProtection(
        _ record: CleanupDeviceRecord,
        target: CleanupTarget,
        inventory: CleanupInventory,
        staleBoundary: Date
    ) -> ProtectedCleanupTarget? {
        if inventory.hasActiveXcodeTests {
            return protection(target, .activeTests, "An Xcode test action is active")
        }
        guard !record.identifier.isEmpty else {
            return protection(target, .missingIdentifier, "Device identifier is missing")
        }
        guard record.state == "Shutdown" else {
            return protection(target, .booted, "Device is not shut down")
        }
        guard let lastUsedAt = record.lastUsedAt else {
            return protection(target, .missingLastUsedAt, "Last-used date is missing")
        }
        guard validDataPath(record.dataPath, identifier: record.identifier) else {
            return protection(target, .invalidDataPath, "Device data path does not match its identifier")
        }
        guard lastUsedAt <= staleBoundary else {
            return protection(target, .notOldEnough, "Device was used within 30 days")
        }
        return nil
    }

    private func runtimeProtection(
        _ record: CleanupRuntimeRecord,
        target: CleanupTarget,
        inventory: CleanupInventory,
        bootedRuntimeIDs: Set<String>
    ) -> ProtectedCleanupTarget? {
        if inventory.hasActiveXcodeTests {
            return protection(target, .activeTests, "An Xcode test action is active")
        }
        guard !record.identifier.isEmpty else {
            return protection(target, .missingIdentifier, "Runtime image identifier is missing")
        }
        guard !bootedRuntimeIDs.contains(record.runtimeIdentifier) else {
            return protection(target, .bootedRuntime, "A booted device uses this runtime")
        }
        guard inventory.outdatedRuntimeIDs.contains(record.identifier) else {
            return protection(target, .notOutdated, "Apple does not report this runtime as outdated")
        }
        return nil
    }

    private func validDataPath(_ path: String?, identifier: String) -> Bool {
        guard let path else { return false }
        let actual = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let expected = devicesRoot
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .standardizedFileURL.pathComponents
        return actual == expected
    }

    private func protection(
        _ target: CleanupTarget,
        _ reason: CleanupProtectionReason,
        _ explanation: String
    ) -> ProtectedCleanupTarget {
        ProtectedCleanupTarget(
            target: target,
            reason: reason,
            explanation: explanation
        )
    }

    private func deviceOrder(_ lhs: CleanupTarget, _ rhs: CleanupTarget) -> Bool {
        switch (lhs.lastUsedAt, rhs.lastUsedAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.identifier < rhs.identifier
        }
    }

}
