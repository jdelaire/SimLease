import Darwin
import Foundation

public enum LaneLockError: Error, Equatable {
    case timedOut
    case invalidSlot(Int)
    case systemCall(String, Int32)
}

public final class LaneLockHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32]
    private var processLocks: [NSLock]

    fileprivate init(descriptors: [Int32], processLocks: [NSLock]) {
        self.descriptors = descriptors
        self.processLocks = processLocks
    }

    deinit { release() }

    public func release() {
        lock.lock()
        let held = descriptors
        let heldProcessLocks = processLocks
        descriptors = []
        processLocks = []
        lock.unlock()
        for descriptor in held.reversed() {
            _ = lockf(descriptor, F_ULOCK, 0)
            _ = close(descriptor)
        }
        for processLock in heldProcessLocks.reversed() {
            processLock.unlock()
        }
    }
}

public final class LaneLockCoordinator: @unchecked Sendable {
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var processLocks: [String: NSLock] = [:]

    private let paths: LeasePaths
    private let timing: LeaseTiming
    private let clock: any LeaseClock

    public init(
        paths: LeasePaths,
        timing: LeaseTiming = .production,
        clock: any LeaseClock = SystemLeaseClock()
    ) {
        self.paths = paths
        self.timing = timing
        self.clock = clock
    }

    public func acquire(slot: Int) throws -> LaneLockHandle {
        let acquired = try acquireSlot(slot: slot)
        return LaneLockHandle(
            descriptors: [acquired.descriptor],
            processLocks: [acquired.processLock]
        )
    }

    public func tryAcquire(slot: Int) throws -> LaneLockHandle? {
        guard slot > 0 else { throw LaneLockError.invalidSlot(slot) }
        let processLock = Self.processLock(for: paths.laneCommandLock(slot: slot).path)
        guard processLock.try() else { return nil }
        let descriptor: Int32
        do {
            descriptor = try openDescriptor(slot: slot)
        } catch {
            processLock.unlock()
            throw error
        }
        guard lockf(descriptor, F_TLOCK, 0) == 0 else {
            let code = errno
            _ = close(descriptor)
            processLock.unlock()
            guard code == EACCES || code == EAGAIN else {
                throw LaneLockError.systemCall("lockf", code)
            }
            return nil
        }
        return LaneLockHandle(
            descriptors: [descriptor],
            processLocks: [processLock]
        )
    }

    public func acquireAll(maxSlot: Int) throws -> LaneLockHandle {
        guard maxSlot > 0 else { throw LaneLockError.invalidSlot(maxSlot) }
        var descriptors: [Int32] = []
        var processLocks: [NSLock] = []
        do {
            for slot in 1...maxSlot {
                let acquired = try acquireSlot(slot: slot)
                descriptors.append(acquired.descriptor)
                processLocks.append(acquired.processLock)
            }
            return LaneLockHandle(
                descriptors: descriptors,
                processLocks: processLocks
            )
        } catch {
            LaneLockHandle(
                descriptors: descriptors,
                processLocks: processLocks
            ).release()
            throw error
        }
    }

    private func acquireSlot(slot: Int) throws -> (descriptor: Int32, processLock: NSLock) {
        guard slot > 0 else { throw LaneLockError.invalidSlot(slot) }
        let processLock = Self.processLock(for: paths.laneCommandLock(slot: slot).path)
        let started = clock.monotonicNow()
        while !processLock.try() {
            if started.duration(to: clock.monotonicNow()) >= timing.timeout {
                throw LaneLockError.timedOut
            }
            try clock.sleep(for: timing.pollInterval)
        }
        do {
            return (try acquireDescriptor(slot: slot, started: started), processLock)
        } catch {
            processLock.unlock()
            throw error
        }
    }

    private func acquireDescriptor(slot: Int, started: ContinuousClock.Instant) throws -> Int32 {
        let descriptor = try openDescriptor(slot: slot)
        while true {
            if lockf(descriptor, F_TLOCK, 0) == 0 { return descriptor }
            let code = errno
            guard code == EACCES || code == EAGAIN else {
                _ = close(descriptor)
                throw LaneLockError.systemCall("lockf", code)
            }
            if started.duration(to: clock.monotonicNow()) >= timing.timeout {
                _ = close(descriptor)
                throw LaneLockError.timedOut
            }
            try clock.sleep(for: timing.pollInterval)
        }
    }

    private func openDescriptor(slot: Int) throws -> Int32 {
        guard slot > 0 else { throw LaneLockError.invalidSlot(slot) }
        let url = paths.laneCommandLock(slot: slot)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw LaneLockError.systemCall("mkdir", EIO)
        }
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LaneLockError.systemCall("open", errno)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw LaneLockError.systemCall("fchmod", code)
        }
        return descriptor
    }

    private static func processLock(for path: String) -> NSLock {
        registryLock.withLock {
            if let existing = processLocks[path] { return existing }
            let created = NSLock()
            processLocks[path] = created
            return created
        }
    }
}
