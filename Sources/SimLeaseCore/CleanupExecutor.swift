import Foundation

public final class CleanupExecutor: @unchecked Sendable {
    private let provider: any CleanupInventoryProviding
    private let planner: CleanupPlanner

    public init(
        provider: any CleanupInventoryProviding,
        planner: CleanupPlanner
    ) {
        self.provider = provider
        self.planner = planner
    }

    public func apply(plan: CleanupPlan, now: Date) throws -> CleanupResult {
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
            guard eligibility(of: target, in: current, now: now) else {
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
            guard eligibility(of: target, in: current, now: now) else {
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

    private func eligibility(
        of target: CleanupTarget,
        in inventory: CleanupInventory,
        now: Date
    ) -> Bool {
        let review = planner.makeReview(
            inventory: inventory,
            now: now,
            id: "VERIFY"
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
