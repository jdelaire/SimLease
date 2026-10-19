import Foundation
import Darwin

public enum LeaseAcquisitionError: Error, Equatable {
    case timedOut
    case cancelled(Int32)
    case systemCall(String, Int32)
}

public final class LeaseHandle: @unchecked Sendable {
    public let owner: LeaseOwner
    private let store: MetadataStore
    private let stateLock = NSLock()
    private var fileDescriptor: Int32?

    fileprivate init(owner: LeaseOwner, store: MetadataStore, fileDescriptor: Int32) {
        self.owner = owner
        self.store = store
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        release()
    }

    public func release() {
        stateLock.lock()
        guard let descriptor = fileDescriptor else {
            stateLock.unlock()
            return
        }
        fileDescriptor = nil
        stateLock.unlock()

        HostLaneLock.release(paths: store.paths, descriptor: descriptor) {
            try? store.removeOwner()
        }
    }
}

public final class LeaseCoordinator: @unchecked Sendable {
    private let paths: LeasePaths
    private let store: MetadataStore
    private let timing: LeaseTiming
    private let clock: any LeaseClock
    private let processInspector: any ProcessIdentityInspecting

    public init(
        paths: LeasePaths,
        store: MetadataStore,
        timing: LeaseTiming = .production,
        clock: any LeaseClock = SystemLeaseClock(),
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector()
    ) {
        self.paths = paths
        self.store = store
        self.timing = timing
        self.clock = clock
        self.processInspector = processInspector
    }

    public func acquire(
        identity: LeaseIdentity,
        onWaitReport: @escaping @Sendable (LeaseStatus) -> Void = { _ in },
        cancellationSignal: @escaping @Sendable () -> Int32? = { nil },
        allowUnfinishedTask: Bool = false,
        allowUnfinishedRepair: Bool = false,
        deviceIDs: [String] = []
    ) throws -> LeaseHandle {
        let started = clock.monotonicNow()
        var nextReport = timing.reportInterval
        let waitingSince = clock.wallNow()
        let waiter = LeaseWaiter(
            id: "\(identity.pid)-\(UUID().uuidString)",
            pid: identity.pid,
            waitingSince: waitingSince,
            cwd: identity.cwd,
            project: identity.project,
            command: identity.command,
            source: identity.source,
            threadID: identity.threadID,
            threadTitle: identity.threadTitle,
            deviceIDs: deviceIDs.isEmpty ? nil : deviceIDs
        )

        try store.writeWaiter(waiter)
        defer { try? store.removeWaiter(id: waiter.id) }

        while true {
            if let handle = try tryAcquire(identity: identity, allowUnfinishedTask: allowUnfinishedTask, allowUnfinishedRepair: allowUnfinishedRepair) {
                try store.removeWaiter(id: waiter.id)
                return handle
            }

            if let signal = cancellationSignal() {
                throw LeaseAcquisitionError.cancelled(signal)
            }

            let elapsed = started.duration(to: clock.monotonicNow())
            if elapsed >= timing.timeout {
                throw LeaseAcquisitionError.timedOut
            }
            if elapsed >= nextReport {
                onWaitReport(try status())
                nextReport += timing.reportInterval
            }
            try clock.sleep(for: timing.pollInterval)
        }
    }

    public func tryAcquire(identity: LeaseIdentity, allowUnfinishedTask: Bool = false, allowUnfinishedRepair: Bool = false) throws -> LeaseHandle? {
        guard let descriptor = try HostLaneLock.acquire(paths: paths) else {
            return nil
        }

        let owner = LeaseOwner(
            pid: identity.pid,
            acquiredAt: clock.wallNow(),
            cwd: identity.cwd,
            project: identity.project,
            command: identity.command,
            source: identity.source,
            threadID: identity.threadID,
            threadTitle: identity.threadTitle
        )
        do {
            if !allowUnfinishedRepair, FileManager.default.fileExists(atPath: paths.deviceRecovery.path) {
                throw SimulatorTaskError.unfinishedTask("device recovery is unresolved; resume simlease device repair with --settled")
            }
            if !allowUnfinishedTask, let record = try SimulatorTaskStore(paths: paths).read() {
                throw SimulatorTaskError.unfinishedTask(record.failure ?? record.phase.rawValue)
            }
            try store.writeOwner(owner)
            return LeaseHandle(owner: owner, store: store, fileDescriptor: descriptor)
        } catch {
            HostLaneLock.release(paths: paths, descriptor: descriptor) {}
            throw error
        }
    }

    public func status() throws -> LeaseStatus {
        try HostLaneLock.probe(paths: paths) { isFree in
            try status(isFree: isFree)
        }
    }

    private func status(isFree: Bool) throws -> LeaseStatus {
        let waiters: [LeaseWaiter]
        do {
            waiters = try activeWaiters(from: store.readWaiters())
        } catch {
            return LeaseStatus(
                state: .metadataError,
                owner: nil,
                waiters: [],
                error: "waiter metadata error: \(error)"
            )
        }

        let owner: LeaseOwner?
        do {
            owner = try store.readOwner()
        } catch {
            return LeaseStatus(
                state: .metadataError,
                owner: nil,
                waiters: waiters,
                error: "owner metadata error: \(error)"
            )
        }

        if isFree {
            if FileManager.default.fileExists(atPath: paths.deviceRecovery.path) {
                return LeaseStatus(state: .metadataError, owner: owner, waiters: waiters, error: "unfinished device recovery; resume simlease device repair with --settled")
            }
            do {
                if let record = try SimulatorTaskStore(paths: paths).read() {
                    return LeaseStatus(state: .metadataError, owner: owner, waiters: waiters, error: "unfinished task \(record.token): \(record.failure ?? record.phase.rawValue); run simlease recover")
                }
            } catch {
                return LeaseStatus(state: .metadataError, owner: owner, waiters: waiters, error: "task metadata error: \(error)")
            }
            guard owner == nil else {
                return LeaseStatus(
                    state: .metadataError,
                    owner: owner,
                    waiters: waiters,
                    error: "owner metadata exists while lease is free"
                )
            }
            return LeaseStatus(state: .free, owner: nil, waiters: waiters, error: nil)
        }

        guard let owner else {
            return LeaseStatus(
                state: .metadataError,
                owner: nil,
                waiters: waiters,
                error: "owner metadata missing while lease is held"
            )
        }
        return LeaseStatus(state: .leased, owner: owner, waiters: waiters, error: nil)
    }

    private func activeWaiters(
        from recordedWaiters: [LeaseWaiter]
    ) throws -> [LeaseWaiter] {
        var active: [LeaseWaiter] = []
        for waiter in recordedWaiters {
            switch processInspector.identityState(
                pid: waiter.pid,
                waitingSince: waiter.waitingSince
            ) {
            case .missing, .reused:
                try store.removeWaiter(id: waiter.id)
            case .matching, .unknown:
                active.append(waiter)
            }
        }
        return active
    }

}
