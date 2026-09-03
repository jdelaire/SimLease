import Foundation

public final class CleanupExecutor: @unchecked Sendable {
    private let provider: any CleanupInventoryProviding
    private let planner: CleanupPlanner
    private let storageProvider: (any XcodeStorageInventoryProviding)?
    private let fileOperator: (any CleanupFileOperating)?
    private let laneProtectionProvider: @Sendable () throws -> LaneProtectionSnapshot

    public init(
        provider: any CleanupInventoryProviding,
        planner: CleanupPlanner,
        storageProvider: (any XcodeStorageInventoryProviding)? = nil,
        fileOperator: (any CleanupFileOperating)? = nil,
        laneProtectionProvider: @Sendable @escaping () throws -> LaneProtectionSnapshot = {
            .empty
        }
    ) {
        self.provider = provider
        self.planner = planner
        self.storageProvider = storageProvider
        self.fileOperator = fileOperator
        self.laneProtectionProvider = laneProtectionProvider
    }

    public func apply(plan: CleanupPlan, now: Date) throws -> CleanupResult {
        try apply(
            plan: plan,
            selectedTargetIDs: Set(plan.targets.map(\.identifier)),
            now: now
        )
    }

    public func apply(
        plan: CleanupPlan,
        selectedTargetIDs: Set<String>,
        now: Date
    ) throws -> CleanupResult {
        let selectedDevices = plan.devices.filter {
            selectedTargetIDs.contains($0.identifier)
        }
        let selectedRuntimes = plan.runtimes.filter {
            selectedTargetIDs.contains($0.identifier)
        }
        let selectedStorage = plan.storage.filter {
            selectedTargetIDs.contains($0.identifier)
        }
        let simulatorPlan = CleanupPlan(
            id: plan.id,
            createdAt: plan.createdAt,
            expiresAt: plan.expiresAt,
            devices: selectedDevices,
            runtimes: selectedRuntimes,
            protected: plan.protected,
            deferred: plan.deferred,
            estimatedBytes: (selectedDevices + selectedRuntimes).reduce(0) {
                $0 + ($1.sizeBytes ?? 0)
            },
            availableBytesBefore: plan.availableBytesBefore
        )
        let laneProtection = try? laneProtectionProvider()
        let simulatorResult: CleanupResult?
        if selectedDevices.isEmpty && selectedRuntimes.isEmpty {
            simulatorResult = nil
        } else {
            simulatorResult = try applySimulator(
                plan: simulatorPlan,
                now: now,
                laneProtection: laneProtection
            )
        }

        var items = simulatorResult?.items ?? []
        items.append(
            contentsOf: applyStorage(
                selectedStorage,
                now: now,
                laneProtection: laneProtection
            )
        )
        let estimatedBytes = (
            selectedDevices + selectedRuntimes + selectedStorage
        ).reduce(Int64(0)) {
            $0 + ($1.sizeBytes ?? 0)
        }
        return CleanupResult(
            planID: plan.id,
            items: items,
            estimatedBytes: estimatedBytes,
            availableBytesBefore:
                simulatorResult?.availableBytesBefore
                    ?? plan.availableBytesBefore,
            availableBytesAfter: simulatorResult?.availableBytesAfter
        )
    }

    private func applySimulator(
        plan: CleanupPlan,
        now: Date,
        laneProtection: LaneProtectionSnapshot?
    ) throws -> CleanupResult {
        let initial = try provider.inventory()
        var items = [CleanupItemResult]()
        var blockReason = initial.hasActiveXcodeTests
            ? "An Xcode test action is active"
            : nil

        for target in plan.devices {
            if let blockReason {
                items.append(skipped(target, blockReason))
                continue
            }
            guard let laneProtection else {
                items.append(skipped(target, "Lane protection revalidation failed"))
                continue
            }
            if laneProtection.reservedDeviceIDs.contains(target.identifier) {
                items.append(skipped(
                    target,
                    "Reserved by a managed simulator lane since review"
                ))
                continue
            }
            let current: CleanupInventory
            do {
                current = try provider.inventory()
            } catch {
                blockReason = "Inventory revalidation failed: \(error)"
                items.append(skipped(target, blockReason!))
                continue
            }
            if current.hasActiveXcodeTests {
                blockReason = "An Xcode test action is active"
                items.append(skipped(target, blockReason!))
                continue
            }
            guard eligibility(
                of: target,
                in: current,
                now: now,
                laneProtection: laneProtection
            ) else {
                items.append(skipped(target, "Device is no longer eligible"))
                continue
            }
            do {
                try provider.deleteDevice(id: target.identifier)
                items.append(deleted(target))
            } catch where isInvalidDevice(error) {
                _ = try? provider.inventory()
                items.append(skipped(target, "Device disappeared before deletion"))
            } catch {
                items.append(failed(target, error))
            }
        }

        if blockReason == nil, !plan.runtimes.isEmpty {
            do {
                let runtimePhase = try provider.inventory()
                if runtimePhase.hasActiveXcodeTests {
                    blockReason = "An Xcode test action is active"
                }
            } catch {
                blockReason = "Runtime inventory revalidation failed: \(error)"
            }
        }

        for target in plan.runtimes {
            if let blockReason {
                items.append(skipped(target, blockReason))
                continue
            }
            guard let laneProtection else {
                items.append(skipped(target, "Lane protection revalidation failed"))
                continue
            }
            let current: CleanupInventory
            do {
                current = try provider.inventory()
            } catch {
                blockReason = "Inventory revalidation failed: \(error)"
                items.append(skipped(target, blockReason!))
                continue
            }
            if current.hasActiveXcodeTests {
                blockReason = "An Xcode test action is active"
                items.append(skipped(target, blockReason!))
                continue
            }
            guard eligibility(
                of: target,
                in: current,
                now: now,
                laneProtection: laneProtection
            ) else {
                items.append(skipped(target, "Runtime is no longer eligible"))
                continue
            }
            do {
                try provider.deleteRuntime(id: target.identifier)
                items.append(deleted(target))
            } catch {
                items.append(failed(target, error))
            }
        }

        let final = try? provider.inventory()
        return CleanupResult(
            planID: plan.id,
            items: items,
            estimatedBytes: plan.estimatedBytes,
            availableBytesBefore: initial.availableBytes,
            availableBytesAfter: final?.availableBytes
        )
    }

    private func applyStorage(
        _ targets: [CleanupTarget],
        now: Date,
        laneProtection: LaneProtectionSnapshot?
    ) -> [CleanupItemResult] {
        guard !targets.isEmpty else { return [] }
        guard let laneProtection else {
            return targets.map {
                skipped($0, "Lane protection revalidation failed")
            }
        }
        guard let storageProvider, let fileOperator else {
            return targets.map {
                skipped($0, "Filesystem cleanup is unavailable")
            }
        }
        let current: XcodeStorageInventory
        do {
            current = try storageProvider.inventory(now: now)
        } catch {
            return targets.map {
                skipped(
                    $0,
                    "Storage inventory revalidation failed: \(error)"
                )
            }
        }
        let protectedIDs = Set(current.protected.map(\.target.identifier))

        return targets.map { target in
            guard !protectedIDs.contains(target.identifier) else {
                return skipped(target, "A running build or test uses this path")
            }
            if let path = target.path, laneProtection.protects(path: path) {
                return skipped(target, "A managed simulator lane uses this path")
            }
            guard let candidate = current.targets.first(where: {
                $0.identifier == target.identifier
            }) else {
                return skipped(target, "Target is missing or no longer eligible")
            }
            guard candidate.fingerprint == target.fingerprint,
                  candidate.path == target.path,
                  candidate.action == target.action,
                  let path = target.path
            else {
                return skipped(target, "Target changed since review")
            }
            do {
                let url = URL(fileURLWithPath: path)
                switch target.action {
                case .deletePermanently:
                    try fileOperator.delete(url)
                    return deleted(target)
                case .moveToTrash:
                    try fileOperator.trash(url)
                    return CleanupItemResult(
                        target: target,
                        outcome: .movedToTrash,
                        message: "Moved to Trash"
                    )
                }
            } catch {
                return failed(target, error)
            }
        }
    }

    private func eligibility(
        of target: CleanupTarget,
        in inventory: CleanupInventory,
        now: Date,
        laneProtection: LaneProtectionSnapshot
    ) -> Bool {
        let review = planner.makeReview(
            inventory: inventory,
            now: now,
            id: "VERIFY",
            laneProtection: laneProtection
        )
        switch target.kind {
        case .device:
            return review.plan?.devices.contains {
                $0.kind == target.kind && $0.identifier == target.identifier
            } == true
        case .runtime:
            return review.plan?.runtimes.contains {
                $0.kind == target.kind && $0.identifier == target.identifier
            } == true
        case .filesystem:
            return false
        }
    }

    private func isInvalidDevice(_ error: Error) -> Bool {
        guard case let CleanupInventoryError.commandFailed(_, _, stderr) = error
        else {
            return false
        }
        return stderr.contains("Invalid device")
    }

    private func deleted(_ target: CleanupTarget) -> CleanupItemResult {
        CleanupItemResult(
            target: target,
            outcome: .deleted,
            message: "Deleted"
        )
    }

    private func skipped(
        _ target: CleanupTarget,
        _ message: String
    ) -> CleanupItemResult {
        CleanupItemResult(
            target: target,
            outcome: .skipped,
            message: message
        )
    }

    private func failed(
        _ target: CleanupTarget,
        _ error: Error
    ) -> CleanupItemResult {
        CleanupItemResult(
            target: target,
            outcome: .failed,
            message: String(describing: error)
        )
    }
}
