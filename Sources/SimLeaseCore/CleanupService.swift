import Foundation

public protocol CleanupServicing: Sendable {
    func createPlan() throws -> CleanupReview
    func apply(
        planID: String,
        selectedTargetIDs: Set<String>
    ) throws -> CleanupResult
}

public enum CleanupServiceError: Error, Equatable {
    case leaseBusy(LeaseStatus)
    case plan(CleanupPlanStoreError)
    case inventory(CleanupInventoryError)
}

public final class CleanupService: CleanupServicing, @unchecked Sendable {
    private let coordinator: LeaseCoordinator
    private let identity: LeaseIdentity
    private let provider: any CleanupInventoryProviding
    private let planner: CleanupPlanner
    private let store: CleanupPlanStore
    private let executor: CleanupExecutor
    private let storageProvider: (any XcodeStorageInventoryProviding)?
    private let forceDeferredSimulatorCleanup: Bool
    private let now: @Sendable () -> Date
    private let idGenerator: @Sendable () -> String

    public init(
        coordinator: LeaseCoordinator,
        identity: LeaseIdentity,
        provider: any CleanupInventoryProviding,
        planner: CleanupPlanner,
        store: CleanupPlanStore,
        executor: CleanupExecutor,
        storageProvider: (any XcodeStorageInventoryProviding)? = nil,
        forceDeferredSimulatorCleanup: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init,
        idGenerator: @escaping @Sendable () -> String = {
            CleanupService.makeID()
        }
    ) {
        self.coordinator = coordinator
        self.identity = identity
        self.provider = provider
        self.planner = planner
        self.store = store
        self.executor = executor
        self.storageProvider = storageProvider
        self.forceDeferredSimulatorCleanup = forceDeferredSimulatorCleanup
        self.now = now
        self.idGenerator = idGenerator
    }

    public func createPlan() throws -> CleanupReview {
        let currentNow = now()
        try store.prune(now: currentNow)
        let storage = try storageProvider?.inventory(now: currentNow)
            ?? XcodeStorageInventory(targets: [], protected: [])
        var simulatorInventory: CleanupInventory?
        var deferred = [CleanupCategory]()
        let status = try coordinator.status()
        if forceDeferredSimulatorCleanup {
            deferred = [.simulatorDevice, .simulatorRuntime]
        } else if status.state == .free,
           let handle = try coordinator.tryAcquire(identity: identity) {
            defer { handle.release() }
            do {
                simulatorInventory = try provider.inventory()
            } catch let error as CleanupInventoryError {
                throw CleanupServiceError.inventory(error)
            }
        } else {
            deferred = [.simulatorDevice, .simulatorRuntime]
        }

        while true {
            let review = planner.makeReview(
                inventory: simulatorInventory,
                storage: storage,
                deferred: deferred,
                now: currentNow,
                id: idGenerator()
            )
            guard let plan = review.plan else { return review }
            do {
                try store.save(plan)
                return review
            } catch CleanupPlanStoreError.alreadyExists {
                continue
            } catch let error as CleanupPlanStoreError {
                throw CleanupServiceError.plan(error)
            }
        }
    }

    public func apply(planID: String) throws -> CleanupResult {
        try apply(planID: planID, selectedTargetIDs: nil)
    }

    public func apply(
        planID: String,
        selectedTargetIDs: Set<String>
    ) throws -> CleanupResult {
        try apply(
            planID: planID,
            selectedTargetIDs: Optional(selectedTargetIDs)
        )
    }

    private func apply(
        planID: String,
        selectedTargetIDs: Set<String>?
    ) throws -> CleanupResult {
        let currentNow = now()
        let plan: CleanupPlan
        do {
            plan = try store.consume(id: planID, now: currentNow)
        } catch let error as CleanupPlanStoreError {
            throw CleanupServiceError.plan(error)
        }
        var selection = selectedTargetIDs
            ?? Set(plan.targets.map(\.identifier))
        let simulatorIDs = Set(
            (plan.devices + plan.runtimes).map(\.identifier)
        ).intersection(selection)
        var deferredItems = [CleanupItemResult]()
        var handle: LeaseHandle?
        if forceDeferredSimulatorCleanup {
            selection.subtract(simulatorIDs)
            deferredItems = plan.targets
                .filter { simulatorIDs.contains($0.identifier) }
                .map {
                    CleanupItemResult(
                        target: $0,
                        outcome: .skipped,
                        message: "Managed lane metadata is unavailable"
                    )
                }
        } else if !simulatorIDs.isEmpty {
            handle = try coordinator.tryAcquire(identity: identity)
            if handle == nil {
                selection.subtract(simulatorIDs)
                deferredItems = plan.targets
                    .filter { simulatorIDs.contains($0.identifier) }
                    .map {
                        CleanupItemResult(
                            target: $0,
                            outcome: .skipped,
                            message: "Simulator lease is in use"
                        )
                    }
            }
        }
        defer { handle?.release() }
        do {
            let result = try executor.apply(
                plan: plan,
                selectedTargetIDs: selection,
                now: currentNow
            )
            guard !deferredItems.isEmpty else { return result }
            return CleanupResult(
                planID: result.planID,
                items: deferredItems + result.items,
                estimatedBytes: result.estimatedBytes,
                availableBytesBefore: result.availableBytesBefore,
                availableBytesAfter: result.availableBytesAfter
            )
        } catch let error as CleanupInventoryError {
            throw CleanupServiceError.inventory(error)
        }
    }

    @usableFromInline
    internal static func makeID() -> String {
        let characters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in
            characters.randomElement()!
        })
    }
}
