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

        try? store.removeOwner()
        _ = lockf(descriptor, F_ULOCK, 0)
        _ = close(descriptor)
    }
}

public final class LeaseCoordinator: @unchecked Sendable {
    private let paths: LeasePaths
    private let store: MetadataStore
    private let timing: LeaseTiming
    private let clock: any LeaseClock

    public init(
        paths: LeasePaths,
        store: MetadataStore,
        timing: LeaseTiming = .production,
        clock: any LeaseClock = SystemLeaseClock()
    ) {
        self.paths = paths
        self.store = store
        self.timing = timing
        self.clock = clock
    }

    public func acquire(
        identity: LeaseIdentity,
        onWaitReport: @escaping @Sendable (LeaseStatus) -> Void = { _ in },
        cancellationSignal: @escaping @Sendable () -> Int32? = { nil }
    ) throws -> LeaseHandle {
        let descriptor = try openLock()
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
            threadTitle: identity.threadTitle
        )

        do {
            try store.writeWaiter(waiter)
        } catch {
            _ = close(descriptor)
            throw error
        }

        var acquired = false
        defer {
            if !acquired {
                try? store.removeWaiter(id: waiter.id)
                _ = close(descriptor)
            }
        }

        while true {
            if lockf(descriptor, F_TLOCK, 0) == 0 {
                try store.removeWaiter(id: waiter.id)
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
                    try store.writeOwner(owner)
                } catch {
                    _ = lockf(descriptor, F_ULOCK, 0)
                    throw error
                }
                acquired = true
                return LeaseHandle(owner: owner, store: store, fileDescriptor: descriptor)
            }

            let code = errno
            guard code == EACCES || code == EAGAIN else {
                throw LeaseAcquisitionError.systemCall("lockf", code)
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

    public func tryAcquire(identity: LeaseIdentity) throws -> LeaseHandle? {
        let descriptor = try openLock()
        guard lockf(descriptor, F_TLOCK, 0) == 0 else {
            let code = errno
            _ = close(descriptor)
            guard code == EACCES || code == EAGAIN else {
                throw LeaseAcquisitionError.systemCall("lockf", code)
            }
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
            try store.writeOwner(owner)
            return LeaseHandle(owner: owner, store: store, fileDescriptor: descriptor)
        } catch {
            _ = lockf(descriptor, F_ULOCK, 0)
            _ = close(descriptor)
            throw error
        }
    }

    public func status() throws -> LeaseStatus {
        let descriptor = try openLock()
        let probe = lockf(descriptor, F_TLOCK, 0)
        let isFree = probe == 0
        let code = errno
        guard isFree || code == EACCES || code == EAGAIN else {
            _ = close(descriptor)
            throw LeaseAcquisitionError.systemCall("lockf", code)
        }

        defer {
            if isFree {
                _ = lockf(descriptor, F_ULOCK, 0)
            }
            _ = close(descriptor)
        }

        let waiters: [LeaseWaiter]
        do {
            waiters = try store.readWaiters()
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

    private func openLock() throws -> Int32 {
        let descriptor = open(paths.lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LeaseAcquisitionError.systemCall("open", errno)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw LeaseAcquisitionError.systemCall("fchmod", code)
        }
        return descriptor
    }
}
