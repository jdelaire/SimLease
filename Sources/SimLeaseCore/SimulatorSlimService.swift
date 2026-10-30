import Foundation
import Synchronization

public protocol SimulatorLaunchdControlling: Sendable {
    func launchctl(_ deviceID: String, _ arguments: [String]) throws -> String
}

public struct SlimProfile: Codable, Equatable, Sendable {
    public let keep: [String]
    public let disabledCount: Int
    public let appliedAt: Date
    public let complete: Bool

    public init(keep: [String], disabledCount: Int, appliedAt: Date, complete: Bool) {
        self.keep = keep
        self.disabledCount = disabledCount
        self.appliedAt = appliedAt
        self.complete = complete
    }

    public var disablesPosterBoard: Bool {
        (try? SimulatorServiceCatalog.desired(keep: Set(keep)).contains("com.apple.PosterBoard")) == true
    }
}

public struct SlimProfileStore: Sendable {
    private let paths: LeasePaths
    private let url: URL

    public init(paths: LeasePaths) {
        self.paths = paths
        url = paths.root.appendingPathComponent("slim-profiles.json")
    }

    public func read() throws -> [String: SlimProfile] {
        do { return try RecoveryFile.read([String: SlimProfile].self, at: url) ?? [:] }
        catch { throw MetadataStoreError.corruptFile(url) }
    }

    public func set(_ id: String, _ profile: SlimProfile?) throws {
        try SharedStateLock.withLock(paths) {
            var profiles = try read()
            profiles[id.uppercased()] = profile
            try RecoveryFile.write(profiles, at: url)
        }
    }
}

public struct SlimResult: Codable, Equatable, Sendable {
    public let deviceID: String
    public let state: String
    public let disabledCount: Int
    public let keep: [String]
}

public struct SimulatorSlimService: Sendable {
    static let purpose = "slim"

    private let paths: LeasePaths
    private let coordinator: LeaseCoordinator
    private let identity: LeaseIdentity
    private let devices: any SimulatorDeviceManaging
    private let launchd: any SimulatorLaunchdControlling
    private let inspect: @Sendable () throws -> Void
    private let now: @Sendable () -> Date
    private let delays: [TimeInterval]

    public init(
        paths: LeasePaths, coordinator: LeaseCoordinator, identity: LeaseIdentity,
        devices: any SimulatorDeviceManaging, launchd: any SimulatorLaunchdControlling,
        inspect: @escaping @Sendable () throws -> Void, now: @escaping @Sendable () -> Date = Date.init,
        delays: [TimeInterval] = [1, 2, 4, 8]
    ) {
        self.paths = paths
        self.coordinator = coordinator
        self.identity = identity
        self.devices = devices
        self.launchd = launchd
        self.inspect = inspect
        self.now = now
        self.delays = delays
    }

    public func slim(deviceID: String, keep: Set<String>, settled: Bool) throws -> SlimResult {
        try converge(deviceID.uppercased(), keep: keep, settled: settled)
    }

    public func unslim(deviceID: String, settled: Bool) throws -> SlimResult {
        try converge(deviceID.uppercased(), keep: nil, settled: settled)
    }

    public func disabledLabels(_ id: String) throws -> Set<String> {
        SimulatorServiceCatalog.parseDisabled(try launchd.launchctl(id, ["print-disabled", "system"]))
    }

    private func converge(_ id: String, keep: Set<String>?, settled: Bool) throws -> SlimResult {
        let desired = try keep.map { try SimulatorServiceCatalog.desired(keep: $0) } ?? []
        let handle = try coordinator.acquire(identity: identity, allowUnfinishedRepair: true)
        defer { handle.release() }
        var resuming = false
        if let pending = try RecoveryFile.read(DeviceRepairTransaction.self, at: paths.deviceRecovery) {
            guard pending.purpose == Self.purpose, pending.original?.id == id else {
                throw DeviceManagementError.failed("another device recovery is pending; settle it before changing slim profiles")
            }
            guard settled else { throw DeviceManagementError.unsettled("previous slim change for \(id) is unfinished") }
            let current = try ProcessReference.current()
            guard pending.owner.state != .unknown, pending.owner.state != .matching || pending.owner == current else {
                throw SimulatorTaskError.unverifiedProcess(pending.owner.pid)
            }
            resuming = true
        }
        try inspect()
        guard let device = try devices.inventory().first(where: { $0.id == id }) else { throw SimulatorTaskError.unknownDevice(id) }
        guard device.available, try !devices.pairedDeviceIDs().contains(id) else {
            throw DeviceManagementError.failed("slim profiles require an available, unpaired simulator")
        }
        guard SimulatorServiceCatalog.supportsPersistentOverrides(runtime: device.runtime) else {
            throw DeviceManagementError.failed("slim profiles require an iOS 18.5 or newer runtime; \(SimulatorUsage.runtimeName(device.runtime)) does not keep launchd overrides across reboots")
        }
        if keep != nil, try CrashLoopStore(paths: paths).read().blocks[id] != nil {
            throw DeviceManagementError.failed("simulator \(id) is crash blocked; resolve the block before slimming")
        }
        guard device.state == "Shutdown" || resuming else {
            throw DeviceManagementError.failed("slim profiles change only Shutdown simulators; shut down \(id) first")
        }
        let transaction = DeviceRepairTransaction(
            id: UUID().uuidString, owner: try ProcessReference.current(), original: device,
            name: device.name, deviceType: device.deviceType, runtime: device.runtime, purpose: Self.purpose
        )
        try RecoveryFile.write(transaction, at: paths.deviceRecovery)
        let store = SlimProfileStore(paths: paths)
        let recorded = try store.read()[id]
        if let keep {
            try store.set(id, SlimProfile(keep: keep.sorted(), disabledCount: desired.count, appliedAt: now(), complete: false))
        } else if let recorded {
            try store.set(id, SlimProfile(keep: recorded.keep, disabledCount: recorded.disabledCount, appliedAt: recorded.appliedAt, complete: false))
        }
        let changed: Bool
        do {
            if device.state != "Shutdown" { try devices.shutdown(id) }
            try devices.bootAndWait(id)
            let delta = SimulatorServiceCatalog.delta(current: try readDisabled(id), desired: desired)
            changed = !delta.disable.isEmpty || !delta.enable.isEmpty
            if changed {
                try apply(id, delta)
                try devices.shutdown(id)
                try devices.bootAndWait(id)
                let remaining = SimulatorServiceCatalog.delta(current: try readDisabled(id), desired: desired)
                let lost = remaining.disable.count + remaining.enable.count
                guard lost == 0 else { throw DeviceManagementError.failed("\(lost) launchd overrides did not persist across reboot on \(id)") }
            }
            try devices.shutdown(id)
        } catch DeviceManagementError.failed(let detail) {
            do {
                try devices.shutdown(id)
                guard try devices.inventory().first(where: { $0.id == id })?.state == "Shutdown" else { throw DeviceManagementError.unsettled("shutdown not verified") }
            } catch {
                throw DeviceManagementError.unsettled("\(detail); shutdown after the failure was not verified")
            }
            try FileManager.default.removeItem(at: paths.deviceRecovery)
            throw DeviceManagementError.failed("\(detail); the slim profile is recorded as incomplete")
        }
        try store.set(id, keep.map { SlimProfile(keep: $0.sorted(), disabledCount: desired.count, appliedAt: now(), complete: true) })
        try FileManager.default.removeItem(at: paths.deviceRecovery)
        let state = changed ? (keep == nil ? "restored" : "slimmed") : "unchanged"
        return SlimResult(deviceID: id, state: state, disabledCount: desired.count, keep: keep?.sorted() ?? [])
    }

    private func readDisabled(_ id: String) throws -> Set<String> {
        var attempt = 0
        while true {
            do { return try disabledLabels(id) }
            catch DeviceManagementError.failed(let detail) {
                guard attempt < delays.count else { throw DeviceManagementError.failed("launchd state of \(id) could not be read: \(detail)") }
                Thread.sleep(forTimeInterval: delays[attempt])
                attempt += 1
            }
        }
    }

    private func apply(_ id: String, _ delta: (disable: [String], enable: [String])) throws {
        var pending = delta.disable.map { ("disable", $0) } + delta.enable.map { ("enable", $0) }
        var failures = [String]()
        for pass in 0..<3 where !pending.isEmpty {
            if pass > 0 { Thread.sleep(forTimeInterval: delays.indices.contains(pass - 1) ? delays[pass - 1] : 0) }
            let outcomes = Mutex([(verb: String, label: String, detail: String)]())
            let uncertain = Mutex([String]())
            for start in stride(from: 0, to: pending.count, by: 8) {
                let chunk = Array(pending[start..<min(start + 8, pending.count)])
                DispatchQueue.concurrentPerform(iterations: chunk.count) { index in
                    let (verb, label) = chunk[index]
                    do { _ = try launchd.launchctl(id, [verb, "system/\(label)"]) }
                    catch DeviceManagementError.failed(let detail) { outcomes.withLock { $0.append((verb, label, detail)) } }
                    catch { uncertain.withLock { $0.append("\(verb) \(label): \(error)") } }
                }
                if let first = uncertain.withLock({ $0.sorted().first }) {
                    throw DeviceManagementError.unsettled("launchctl outcome on \(id) is uncertain (\(first))")
                }
            }
            let failed = outcomes.withLock { $0 }
            failures = failed.map { "\($0.verb) \($0.label): \($0.detail)" }
            pending = failed.map { ($0.verb, $0.label) }
        }
        guard pending.isEmpty else {
            throw DeviceManagementError.failed("\(pending.count) launchd changes failed after 3 attempts: \(failures.sorted().prefix(3).joined(separator: "; "))")
        }
    }
}

public struct SlimProfileCheck: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ok
        case drift
        case incomplete
        case missing
        case notBooted
        case unreadable
    }

    public let deviceID: String
    public let state: State
    public let reenabled: [String]
    public let extraDisabled: [String]

    public init(deviceID: String, state: State, reenabled: [String], extraDisabled: [String]) {
        self.deviceID = deviceID
        self.state = state
        self.reenabled = reenabled
        self.extraDisabled = extraDisabled
    }

    public static func check(deviceID: String, profile: SlimProfile, device: ManagedSimulatorDevice?, disabled: Set<String>?) -> SlimProfileCheck {
        let state: State
        var delta: (disable: [String], enable: [String]) = ([], [])
        if device == nil { state = .missing }
        else if !profile.complete { state = .incomplete }
        else if device?.state != "Booted" { state = .notBooted }
        else if let disabled, let desired = try? SimulatorServiceCatalog.desired(keep: Set(profile.keep)) {
            delta = SimulatorServiceCatalog.delta(current: disabled, desired: desired)
            state = delta.disable.isEmpty && delta.enable.isEmpty ? .ok : .drift
        } else { state = .unreadable }
        return SlimProfileCheck(deviceID: deviceID, state: state, reenabled: delta.disable, extraDisabled: delta.enable)
    }
}
