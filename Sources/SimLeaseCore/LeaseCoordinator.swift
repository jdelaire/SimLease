import Foundation
import Darwin

public enum LeaseAcquisitionError: Error, Equatable {
    case timedOut
    case cancelled(Int32)
    case systemCall(String, Int32)
}

public struct LaneRequest: Equatable, Sendable {
    public let deviceIDs: [String]
    public let exclusive: Bool
    public let laneZeroOnly: Bool
    public let workspaceKey: String?

    public init(deviceIDs: [String], exclusive: Bool, laneZeroOnly: Bool = false, workspaceKey: String? = nil) {
        self.deviceIDs = Array(Set(deviceIDs.map { $0.uppercased() })).sorted()
        self.exclusive = exclusive || deviceIDs.isEmpty
        self.laneZeroOnly = laneZeroOnly
        self.workspaceKey = workspaceKey
    }

    public static let exclusive = LaneRequest(deviceIDs: [], exclusive: true)
}

public final class LeaseHandle: @unchecked Sendable {
    public let owner: LeaseOwner
    public let paths: LeasePaths
    public let lanes: [Int]
    private let laneLocks: [(LeasePaths, Int32)]
    private let resourceLocks: [(URL, Int32)]
    private let stateLock = NSLock()
    private var released = false

    fileprivate init(owner: LeaseOwner, paths: LeasePaths, laneLocks: [(LeasePaths, Int32)], resourceLocks: [(URL, Int32)]) {
        self.owner = owner
        self.paths = paths
        self.lanes = laneLocks.map(\.0.lane)
        self.laneLocks = laneLocks
        self.resourceLocks = resourceLocks
    }

    deinit {
        release()
    }

    public func release() {
        stateLock.lock()
        guard !released else {
            stateLock.unlock()
            return
        }
        released = true
        stateLock.unlock()
        for (lane, descriptor) in laneLocks.reversed() {
            HostLaneLock.release(paths: lane, descriptor: descriptor) {
                try? MetadataStore(paths: lane).removeOwner()
            }
        }
        for (url, descriptor) in resourceLocks.reversed() {
            HostLaneLock.release(url: url, descriptor: descriptor)
        }
    }
}

public final class LeaseCoordinator: @unchecked Sendable {
    public static let heartbeatInterval: TimeInterval = 5
    public static let staleHeartbeat: TimeInterval = 20

    private let paths: LeasePaths
    private let store: MetadataStore
    private let timing: LeaseTiming
    private let clock: any LeaseClock
    private let processInspector: any ProcessIdentityInspecting
    private let gate: HeadroomGate

    public init(
        paths: LeasePaths,
        store: MetadataStore,
        timing: LeaseTiming = .production,
        clock: any LeaseClock = SystemLeaseClock(),
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector(),
        gate: HeadroomGate? = nil
    ) {
        self.paths = paths.lane(0)
        self.store = store
        self.timing = timing
        self.clock = clock
        self.processInspector = processInspector
        self.gate = gate ?? HeadroomGate(paths: paths.lane(0))
    }

    public func acquire(
        identity: LeaseIdentity,
        onWaitReport: @escaping @Sendable (LeaseStatus) -> Void = { _ in },
        cancellationSignal: @escaping @Sendable () -> Int32? = { nil },
        allowUnfinishedTask: Bool = false,
        allowUnfinishedRepair: Bool = false,
        allowUnfinishedShutdown: Bool = false,
        deviceIDs: [String] = [],
        request: LaneRequest = .exclusive
    ) throws -> LeaseHandle {
        let started = clock.monotonicNow()
        var nextReport = timing.reportInterval
        let waitingSince = clock.wallNow()
        let declared = request.exclusive ? deviceIDs : request.deviceIDs
        var waiter = makeWaiter(identity: identity, waitingSince: waitingSince, deviceIDs: declared, exclusive: request.exclusive, heartbeatAt: waitingSince)

        try store.writeWaiter(waiter)
        defer { try? store.removeWaiter(id: waiter.id) }

        while true {
            if let handle = try tryAcquire(identity: identity, allowUnfinishedTask: allowUnfinishedTask, allowUnfinishedRepair: allowUnfinishedRepair, allowUnfinishedShutdown: allowUnfinishedShutdown, request: request, waiter: waiter) {
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
            let now = clock.wallNow()
            if now.timeIntervalSince(waiter.heartbeatAt ?? waitingSince) >= Self.heartbeatInterval {
                waiter = makeWaiter(identity: identity, waitingSince: waitingSince, deviceIDs: declared, exclusive: request.exclusive, heartbeatAt: now, id: waiter.id)
                try? store.writeWaiter(waiter)
            }
            try clock.sleep(for: timing.pollInterval)
        }
    }

    public func tryAcquire(identity: LeaseIdentity, allowUnfinishedTask: Bool = false, allowUnfinishedRepair: Bool = false, allowUnfinishedShutdown: Bool = false, request: LaneRequest = .exclusive) throws -> LeaseHandle? {
        try tryAcquire(identity: identity, allowUnfinishedTask: allowUnfinishedTask, allowUnfinishedRepair: allowUnfinishedRepair, allowUnfinishedShutdown: allowUnfinishedShutdown, request: request, waiter: nil)
    }

    private func tryAcquire(identity: LeaseIdentity, allowUnfinishedTask: Bool, allowUnfinishedRepair: Bool, allowUnfinishedShutdown: Bool, request: LaneRequest, waiter: LeaseWaiter?) throws -> LeaseHandle? {
        let config = LaneConfig.read(paths)
        var laneLocks = [(LeasePaths, Int32)]()
        var resourceLocks = [(URL, Int32)]()
        func releaseAll() {
            for (lane, descriptor) in laneLocks.reversed() { HostLaneLock.release(paths: lane, descriptor: descriptor) {} }
            for (url, descriptor) in resourceLocks.reversed() { HostLaneLock.release(url: url, descriptor: descriptor) }
        }
        if request.exclusive {
            for lane in paths.allLanes {
                guard let descriptor = try HostLaneLock.acquire(paths: lane) else {
                    releaseAll()
                    return nil
                }
                laneLocks.append((lane, descriptor))
            }
        } else {
            if config.maxLanes > 1, let waiter, try blockedByOlderExclusiveWaiter(waiter) { return nil }
            let reserving = try paths.allLanes.filter { lane in
                guard let record = try SimulatorTaskStore(paths: lane).read() else { return false }
                return !Set(record.deviceIDs.map { $0.uppercased() }).isDisjoint(with: request.deviceIDs)
            }
            guard reserving.count <= 1 else { return nil }
            let keys = request.deviceIDs.map(paths.deviceLock) + (request.workspaceKey.map { [paths.workspaceLock($0)] } ?? [])
            for url in keys {
                guard let descriptor = try HostLaneLock.acquire(url: url) else {
                    releaseAll()
                    return nil
                }
                resourceLocks.append((url, descriptor))
            }
            let candidates = reserving.isEmpty
                ? [0] + (config.maxLanes > 1 && !request.laneZeroOnly ? Array(1..<config.maxLanes) : [])
                : [reserving[0].lane]
            for index in candidates {
                if index > 0, reserving.isEmpty, !gate.check(now: clock.wallNow()).open { break }
                if let descriptor = try HostLaneLock.acquire(paths: paths.lane(index)) {
                    laneLocks.append((paths.lane(index), descriptor))
                    break
                }
            }
            guard !laneLocks.isEmpty else {
                releaseAll()
                return nil
            }
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
            if !allowUnfinishedShutdown, FileManager.default.fileExists(atPath: paths.deviceShutdown.path) {
                throw SimulatorTaskError.unfinishedTask("simulator shutdown is unresolved; rerun simlease device shutdown")
            }
            if !allowUnfinishedTask {
                for (lane, _) in laneLocks {
                    if let record = try SimulatorTaskStore(paths: lane).read() {
                        throw SimulatorTaskError.unfinishedTask(record.failure ?? record.phase.rawValue)
                    }
                }
            }
            for (lane, _) in laneLocks { try MetadataStore(paths: lane).writeOwner(owner) }
            gate.recordAdmission(now: owner.acquiredAt)
            return LeaseHandle(owner: owner, paths: laneLocks[0].0, laneLocks: laneLocks, resourceLocks: resourceLocks)
        } catch {
            for (lane, _) in laneLocks { try? MetadataStore(paths: lane).removeOwner() }
            releaseAll()
            throw error
        }
    }

    private func blockedByOlderExclusiveWaiter(_ waiter: LeaseWaiter) throws -> Bool {
        let now = clock.wallNow()
        return try activeWaiters(from: store.readWaiters()).contains { other in
            other.id != waiter.id && other.exclusive == true
                && (other.waitingSince, other.id) < (waiter.waitingSince, waiter.id)
                && now.timeIntervalSince(other.heartbeatAt ?? other.waitingSince) < Self.staleHeartbeat
        }
    }

    private func makeWaiter(identity: LeaseIdentity, waitingSince: Date, deviceIDs: [String], exclusive: Bool, heartbeatAt: Date, id: String? = nil) -> LeaseWaiter {
        LeaseWaiter(
            id: id ?? "\(identity.pid)-\(UUID().uuidString)",
            pid: identity.pid,
            waitingSince: waitingSince,
            cwd: identity.cwd,
            project: identity.project,
            command: identity.command,
            source: identity.source,
            threadID: identity.threadID,
            threadTitle: identity.threadTitle,
            deviceIDs: deviceIDs.isEmpty ? nil : deviceIDs,
            exclusive: exclusive ? true : nil,
            heartbeatAt: heartbeatAt
        )
    }

    public func status() throws -> LeaseStatus {
        let waiters: [LeaseWaiter]
        do {
            waiters = try activeWaiters(from: store.readWaiters())
        } catch {
            return LeaseStatus(state: .metadataError, owner: nil, waiters: [], error: "waiter metadata error: \(error)")
        }
        var lanes = [LaneStatus]()
        var firstOwner: LeaseOwner?
        for lane in paths.allLanes {
            let result: Result<LaneStatus?, LaneMetadataError> = try HostLaneLock.probe(paths: lane) { isFree in
                laneStatus(lane, isFree: isFree)
            }
            switch result {
            case .failure(let failure):
                return LeaseStatus(state: .metadataError, owner: failure.owner, waiters: waiters, error: failure.message)
            case .success(let status):
                guard let status else { continue }
                firstOwner = firstOwner ?? status.owner
                if let index = lanes.firstIndex(where: { $0.owner == status.owner }) {
                    let existing = lanes[index]
                    lanes[index] = LaneStatus(lane: existing.lane, owner: existing.owner, deviceIDs: existing.deviceIDs + status.deviceIDs, exclusive: true)
                } else {
                    lanes.append(status)
                }
            }
        }
        guard let firstOwner else {
            if FileManager.default.fileExists(atPath: paths.deviceRecovery.path) {
                return LeaseStatus(state: .metadataError, owner: nil, waiters: waiters, error: "unfinished device recovery; resume simlease device repair with --settled")
            }
            if FileManager.default.fileExists(atPath: paths.deviceShutdown.path) {
                return LeaseStatus(state: .metadataError, owner: nil, waiters: waiters, error: "unfinished simulator shutdown; rerun simlease device shutdown")
            }
            return LeaseStatus(state: .free, owner: nil, waiters: waiters, error: nil)
        }
        return LeaseStatus(state: .leased, owner: firstOwner, waiters: waiters, error: nil, lanes: lanes)
    }

    private struct LaneMetadataError: Error {
        let message: String
        let owner: LeaseOwner?
    }

    private func laneStatus(_ lane: LeasePaths, isFree: Bool) -> Result<LaneStatus?, LaneMetadataError> {
        let label = lane.lane == 0 ? "" : " in lane \(lane.lane + 1)"
        let owner: LeaseOwner?
        do {
            owner = try MetadataStore(paths: lane).readOwner()
        } catch {
            return .failure(LaneMetadataError(message: "owner metadata error\(label): \(error)", owner: nil))
        }
        let record: SimulatorTaskRecord?
        do {
            record = try SimulatorTaskStore(paths: lane).read()
        } catch {
            return .failure(LaneMetadataError(message: "task metadata error\(label): \(error)", owner: owner))
        }
        if isFree {
            if let record {
                return .failure(LaneMetadataError(message: "unfinished task \(record.token)\(label): \(record.failure ?? record.phase.rawValue); run simlease recover", owner: owner))
            }
            if owner != nil {
                return .failure(LaneMetadataError(message: "owner metadata exists while lease is free\(label)", owner: owner))
            }
            return .success(nil)
        }
        guard let owner else {
            return .failure(LaneMetadataError(message: "owner metadata missing while lease is held\(label)", owner: nil))
        }
        return .success(LaneStatus(lane: lane.lane, owner: owner, deviceIDs: record?.deviceIDs ?? [], exclusive: false))
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
