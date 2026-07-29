import Foundation

public protocol CleanupServicing: Sendable {
    func createPlan() throws -> CleanupReview
    func apply(planID: String) throws -> CleanupResult
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
    private let now: @Sendable () -> Date
    private let idGenerator: @Sendable () -> String

    public init(
        coordinator: LeaseCoordinator,
        identity: LeaseIdentity,
        provider: any CleanupInventoryProviding,
        planner: CleanupPlanner,
        store: CleanupPlanStore,
        executor: CleanupExecutor,
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
        self.now = now
        self.idGenerator = idGenerator
    }

    public func createPlan() throws -> CleanupReview {
        let handle = try acquireLease()
        defer { handle.release() }
        let currentNow = now()
        try store.prune(now: currentNow)
        let inventory: CleanupInventory
        do {
            inventory = try provider.inventory()
        } catch let error as CleanupInventoryError {
            throw CleanupServiceError.inventory(error)
        }

        while true {
            let review = planner.makeReview(
                inventory: inventory,
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
        let handle = try acquireLease()
        defer { handle.release() }
        let currentNow = now()
        let plan: CleanupPlan
        do {
            plan = try store.consume(id: planID, now: currentNow)
        } catch let error as CleanupPlanStoreError {
            throw CleanupServiceError.plan(error)
        }
        do {
            return try executor.apply(plan: plan, now: currentNow)
        } catch let error as CleanupInventoryError {
            throw CleanupServiceError.inventory(error)
        }
    }

    private func acquireLease() throws -> LeaseHandle {
        if let handle = try coordinator.tryAcquire(identity: identity) {
            return handle
        }
        throw CleanupServiceError.leaseBusy(try coordinator.status())
    }

    @usableFromInline
    internal static func makeID() -> String {
        let characters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in
            characters.randomElement()!
        })
    }
}
