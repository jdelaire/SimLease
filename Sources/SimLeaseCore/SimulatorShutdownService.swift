import Foundation

public struct SimulatorShutdownResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case shutdown
        case alreadyShutdown
        case refused
        case unresolved
    }

    public let deviceID: String
    public let name: String?
    public let outcome: Outcome
    public let reason: String?

    public init(deviceID: String, name: String?, outcome: Outcome, reason: String? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.outcome = outcome
        self.reason = reason
    }
}

public struct SimulatorShutdownService: Sendable {
    private struct Journal: Codable {
        let deviceID: String
        let owner: ProcessReference
    }

    private let paths: LeasePaths
    private let coordinator: LeaseCoordinator
    private let identity: LeaseIdentity
    private let devices: any SimulatorDeviceManaging
    private let activity: @Sendable () -> SimulatorActivityReport

    public init(
        paths: LeasePaths, coordinator: LeaseCoordinator, identity: LeaseIdentity, devices: any SimulatorDeviceManaging,
        activity: @escaping @Sendable () -> SimulatorActivityReport = {
            SimulatorActivityAudit().scan(lease: LeaseStatus(state: .free, owner: nil, waiters: [], error: nil), task: nil)
        }
    ) {
        self.paths = paths
        self.coordinator = coordinator
        self.identity = identity
        self.devices = devices
        self.activity = activity
    }

    public func shutdown(deviceIDs: [String]) throws -> [SimulatorShutdownResult] {
        let ids = Array(Set(deviceIDs.map { $0.uppercased() })).sorted()
        let handle = try coordinator.acquire(identity: identity, allowUnfinishedShutdown: true, deviceIDs: ids)
        defer { handle.release() }
        while true {
            if let descriptor = try HostLaneLock.acquire(url: paths.reapLock) {
                defer { HostLaneLock.release(url: paths.reapLock, descriptor: descriptor) }
                return try shutdownHoldingLane(ids)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public func reap(now: Date = Date()) throws -> [SimulatorShutdownResult]? {
        let status = try coordinator.status()
        guard !(status.lanes ?? []).contains(where: \.exclusive),
              !FileManager.default.fileExists(atPath: paths.deviceShutdown.path) || status.state == .free
        else { return nil }
        return try reapWarmHoldingLane(excluding: [], now: now, busy: nil)
    }

    public func reapWarmHoldingLane(excluding: Set<String>, now: Date) throws -> [SimulatorShutdownResult] {
        try reapWarmHoldingLane(excluding: excluding, now: now, busy: []) ?? []
    }

    private func reapWarmHoldingLane(excluding: Set<String>, now: Date, busy: [SimulatorShutdownResult]?) throws -> [SimulatorShutdownResult]? {
        guard let reapLock = try HostLaneLock.acquire(url: paths.reapLock) else { return busy }
        defer { HostLaneLock.release(url: paths.reapLock, descriptor: reapLock) }
        let store = WarmDeviceStore(paths: paths)
        let warm = try store.read()
        guard !warm.isEmpty else { return [] }
        let states = Dictionary(try devices.inventory().map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        try store.remove(warm.keys.filter { states[$0] == nil || states[$0] == "Shutdown" })
        let blocked = try CrashLoopStore(paths: paths).read().blocks
        let candidates = warm.filter { !excluding.contains($0.key) && states[$0.key] != nil && states[$0.key] != "Shutdown" }
        let expired = candidates.filter { now.timeIntervalSince($0.value) >= WarmDeviceStore.idleLimit || blocked[$0.key] != nil }.map(\.key)
        let overflow = candidates.filter { !expired.contains($0.key) }.sorted { $0.value > $1.value }.dropFirst(WarmDeviceStore.capacity).map(\.key)
        var locks = [(URL, Int32)]()
        defer { for (url, descriptor) in locks { HostLaneLock.release(url: url, descriptor: descriptor) } }
        for id in Array(Set(expired + overflow)).sorted() {
            if let descriptor = try HostLaneLock.acquire(url: paths.deviceLock(id)) { locks.append((paths.deviceLock(id), descriptor)) }
        }
        let targets = locks.map { $0.0.deletingPathExtension().lastPathComponent }
        return targets.isEmpty ? [] : try shutdownHoldingLane(targets)
    }

    func shutdownHoldingLane(_ ids: [String]) throws -> [SimulatorShutdownResult] {
        let warm = WarmDeviceStore(paths: paths)
        let pending = try RecoveryFile.read(Journal.self, at: paths.deviceShutdown)?.deviceID
        if let pending, !ids.contains(pending) {
            throw SimulatorTaskError.unfinishedTask("shutdown of \(pending) is unresolved; rerun simlease device shutdown --device \(pending)")
        }
        var results = [SimulatorShutdownResult]()
        for id in pending.map({ [$0] + ids.filter { $0 != pending } }) ?? ids {
            let journaled = id == pending
            guard let device = try devices.inventory().first(where: { $0.id == id }) else {
                if journaled { return results + [SimulatorShutdownResult(deviceID: id, name: nil, outcome: .unresolved, reason: "journaled simulator is missing")] }
                results.append(SimulatorShutdownResult(deviceID: id, name: nil, outcome: .refused, reason: "unknown simulator"))
                continue
            }
            if device.state == "Shutdown" {
                if journaled { try FileManager.default.removeItem(at: paths.deviceShutdown) }
                try warm.remove([id])
                results.append(SimulatorShutdownResult(deviceID: id, name: device.name, outcome: .alreadyShutdown))
                continue
            }
            if let reason = try refusal(id, state: device.state) {
                if journaled { return results + [SimulatorShutdownResult(deviceID: id, name: device.name, outcome: .unresolved, reason: reason)] }
                results.append(SimulatorShutdownResult(deviceID: id, name: device.name, outcome: .refused, reason: reason))
                continue
            }
            try RecoveryFile.write(Journal(deviceID: id, owner: try ProcessReference.current()), at: paths.deviceShutdown)
            do {
                try devices.shutdown(id)
            } catch DeviceManagementError.failed(let detail) {
                guard try devices.inventory().first(where: { $0.id == id })?.state == device.state else {
                    return results + [SimulatorShutdownResult(deviceID: id, name: device.name, outcome: .unresolved, reason: detail)]
                }
                try FileManager.default.removeItem(at: paths.deviceShutdown)
                results.append(SimulatorShutdownResult(deviceID: id, name: device.name, outcome: .refused, reason: detail))
                continue
            } catch DeviceManagementError.unsettled(let detail) {
                return results + [SimulatorShutdownResult(deviceID: id, name: device.name, outcome: .unresolved, reason: detail)]
            }
            try FileManager.default.removeItem(at: paths.deviceShutdown)
            try warm.remove([id])
            results.append(SimulatorShutdownResult(deviceID: id, name: device.name, outcome: .shutdown))
        }
        return results
    }

    private func refusal(_ id: String, state: String) throws -> String? {
        guard state == "Booted" else { return "simulator is \(state)" }
        if try devices.pairedDeviceIDs().contains(id) { return "simulator is paired" }
        let status = try coordinator.status()
        guard status.state != .metadataError else { return status.error ?? "lease metadata is unreadable" }
        if let waiter = status.waiters.first(where: { $0.deviceIDs?.contains { $0.uppercased() == id } == true }) {
            return "queued job \(waiter.threadTitle ?? waiter.project) declared it"
        }
        if SimulatorTaskStore.records(base: paths).contains(where: { _, record in record.deviceIDs.contains { $0.uppercased() == id } }) {
            return "a running or unfinished job declared it"
        }
        let report = activity()
        if let error = report.error { return error }
        if report.isIncomplete { return "\(report.uninspectedProcessCount) processes could not be inspected" }
        if let process = report.activities.first(where: { $0.deviceIDs.contains { $0.uppercased() == id } }) {
            return "\(process.tool) PID \(process.process.pid) targets it"
        }
        if let process = report.activities.first(where: { $0.deviceIDs.isEmpty }) {
            return "\(process.tool) PID \(process.process.pid) has an unknown simulator target"
        }
        return nil
    }
}
