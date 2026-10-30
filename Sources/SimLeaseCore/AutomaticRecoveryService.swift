import Foundation

public enum AutomaticRecoveryPhase: String, Codable, Sendable {
    case waiting
    case restarting
    case verifying
    case cooldown
    case recovered
    case actionRequired
    case history
}

public struct AutomaticRecoveryRecord: Codable, Equatable, Sendable {
    public let deviceID: String
    public var state: AutomaticRecoveryPhase
    public var detail: String
    public var attempts: [Date]
    public var updatedAt: Date
    public var device: ManagedSimulatorDevice?

    public init(deviceID: String, state: AutomaticRecoveryPhase, detail: String, attempts: [Date] = [], updatedAt: Date = Date(), device: ManagedSimulatorDevice? = nil) {
        self.deviceID = deviceID
        self.state = state
        self.detail = detail
        self.attempts = attempts
        self.updatedAt = updatedAt
        self.device = device
    }
}

public struct SimulatorHealthStatus: Codable, Equatable, Sendable {
    public let recoveries: [AutomaticRecoveryRecord]
    public let backgroundIncidentCount: Int
    public let infrastructureBlocks: [CrashLoopTrigger]?

    public init(recoveries: [AutomaticRecoveryRecord], backgroundIncidentCount: Int = 0, infrastructureBlocks: [CrashLoopTrigger] = []) {
        self.infrastructureBlocks = infrastructureBlocks
        self.recoveries = recoveries
        self.backgroundIncidentCount = backgroundIncidentCount
    }
}

public struct AutomaticRecoveryService: Sendable {
    private let paths: LeasePaths
    private let coordinator: LeaseCoordinator
    private let identity: LeaseIdentity
    private let devices: any SimulatorDeviceManaging
    private let activity: @Sendable () -> SimulatorActivityReport
    private let canBoot: @Sendable () -> Bool
    private let servicePIDs: @Sendable (String) throws -> [String: Int32]
    private let inspect: @Sendable () throws -> Bool
    private let monotonicNow: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) -> Void
    private var url: URL { paths.root.appendingPathComponent("automatic-recovery.json") }

    public init(paths: LeasePaths, coordinator: LeaseCoordinator, identity: LeaseIdentity, devices: any SimulatorDeviceManaging,
                activity: @escaping @Sendable () -> SimulatorActivityReport,
                canBoot: @escaping @Sendable () -> Bool,
                servicePIDs: @escaping @Sendable (String) throws -> [String: Int32],
                inspect: @escaping @Sendable () throws -> Bool,
                now: @escaping @Sendable () -> Date = { Date() },
                monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.paths = paths
        self.coordinator = coordinator
        self.identity = identity
        self.devices = devices
        self.activity = activity
        self.canBoot = canBoot
        self.servicePIDs = servicePIDs
        self.inspect = inspect
        self.monotonicNow = monotonicNow
        self.now = now
        self.sleep = sleep
    }

    public func status(inventory: [ManagedSimulatorDevice]? = nil) throws -> SimulatorHealthStatus {
        let crashes = CrashLoopStore(paths: paths)
        let reasons = try crashes.reasons().filter { $0.kind == .criticalInfrastructure }
        let inventory = try inventory ?? RecoveryFile.read([ManagedSimulatorDevice].self, at: paths.root.appendingPathComponent("automatic-inventory.json"))
        let saved = try read()
        var records = [String: AutomaticRecoveryRecord]()
        for reason in reasons {
            let id = reason.trigger.deviceID
            var record = saved[id] ?? AutomaticRecoveryRecord(deviceID: id, state: .waiting, detail: "Automatic restart queued. Waiting for settled work and host headroom.", updatedAt: now())
            if let inventory, !inventory.contains(where: { $0.id == id }) {
                record.state = .history
                record.detail = "Device no longer exists. Crash evidence retained in history."
            } else if record.state == .recovered || (record.state == .history && inventory != nil) {
                record.state = .waiting
                record.detail = "New critical failure. Automatic restart queued."
            }
            if [.restarting, .verifying].contains(record.state),
               let transaction = try RecoveryFile.read(DeviceRepairTransaction.self, at: paths.deviceRecovery), transaction.owner.state != .matching {
                record.state = .actionRequired
                record.detail = "Interrupted recovery needs verified settlement. Device preserved."
            }
            if ![.history, .recovered, .restarting, .verifying, .actionRequired].contains(record.state), record.attempts.filter({ now().timeIntervalSince($0) < 86_400 }).count >= 2 {
                record.state = .actionRequired
            }
            records[id] = record
        }
        for (id, record) in saved where records[id] == nil && record.state == .recovered && now().timeIntervalSince(record.updatedAt) < 86_400 {
            records[id] = record
        }
        let background = try crashes.read().incidents.filter { $0.kind == .backgroundService }.count
        return SimulatorHealthStatus(recoveries: records.values.sorted { $0.deviceID < $1.deviceID }, backgroundIncidentCount: background, infrastructureBlocks: reasons.map(\.trigger))
    }

    public func maintain(onlyDeviceIDs: Set<String>? = nil) throws -> SimulatorHealthStatus {
        let evidenceComplete = try inspect()
        let inventory = try devices.inventory()
        try SharedStateLock.withLock(paths) { try RecoveryFile.write(inventory, at: paths.root.appendingPathComponent("automatic-inventory.json")) }
        let candidates = try status(inventory: inventory).recoveries.filter {
            $0.state != .history && $0.state != .recovered && (onlyDeviceIDs == nil || onlyDeviceIDs!.contains($0.deviceID))
        }
        guard evidenceComplete, !candidates.isEmpty else { return try status(inventory: inventory) }
        let preflightPairs = try devices.pairedDeviceIDs()
        let preflightDate = now()
        let actionable = candidates.contains { record in
            let recent = record.attempts.filter { preflightDate.timeIntervalSince($0) < 86_400 }
            guard recent.count < 2, recent.last.map({ preflightDate.timeIntervalSince($0) >= 600 }) != false,
                  let target = inventory.first(where: { $0.id == record.deviceID }) else { return false }
            return target.state == "Shutdown" && target.available && !preflightPairs.contains(target.id)
                && record.device.map({ $0.matches(target) }) != false
        }
        guard actionable, canBoot() else { return try status(inventory: inventory) }
        guard let handle = try coordinator.tryAcquire(identity: identity, request: .exclusive) else { return try status(inventory: inventory) }
        defer { handle.release() }
        guard let lock = try HostLaneLock.acquire(url: paths.reapLock) else { return try status(inventory: inventory) }
        defer { HostLaneLock.release(url: paths.reapLock, descriptor: lock) }
        let fresh = try devices.inventory()
        let paired = try devices.pairedDeviceIDs()
        let latest = try read()
        let date = now()
        let audit = activity()
        guard !audit.isIncomplete, (audit.nativeClients ?? []).isEmpty else { return try status(inventory: fresh) }
        let tasks = SimulatorTaskStore.records(base: paths)
        var selected: (ManagedSimulatorDevice, AutomaticRecoveryRecord)?
        for candidate in candidates {
            var current = latest[candidate.deviceID] ?? candidate
            let recent = current.attempts.filter { date.timeIntervalSince($0) < 86_400 }
            guard recent.count < 2, recent.last.map({ date.timeIntervalSince($0) >= 600 }) != false else { continue }
            guard let target = fresh.first(where: { $0.id == current.deviceID }) else { continue }
            let active = audit.activities.contains { $0.deviceIDs.isEmpty || $0.deviceIDs.contains(target.id) }
                || tasks.contains { $0.1.deviceIDs.contains(target.id) }
            guard !active, target.state == "Shutdown", target.available, !target.deviceType.isEmpty, !target.dataPath.isEmpty,
                  !paired.contains(target.id), inventory.first(where: { $0.id == target.id })?.matches(target) == true,
                  current.device.map({ $0.matches(target) }) != false else {
                current.state = .waiting
                current.detail = "Waiting for settled work and an available, shutdown, unpaired device with unchanged configuration. Live devices stay protected."
                try save(current)
                continue
            }
            selected = (target, current)
            break
        }
        guard let (device, candidate) = selected else { return try status(inventory: fresh) }
        let id = device.id
        var record = candidate
        guard canBoot(), try inspect() else {
            record.state = .waiting
            record.detail = "Waiting for host headroom and complete crash-report ingestion."
            try save(record)
            return try status(inventory: fresh)
        }
        let crashes = CrashLoopStore(paths: paths)
        let expected = try crashes.reasons().filter { $0.kind == .criticalInfrastructure && $0.trigger.deviceID == id }
        guard !expected.isEmpty else { return try status(inventory: fresh) }
        record.device = device
        record.attempts = record.attempts.filter { date.timeIntervalSince($0) < 86_400 } + [date]
        record.state = .restarting
        record.detail = "Restarting simulator. App data preserved."
        try save(record)
        do {
            let repair = DeviceRepairService(paths: paths, coordinator: coordinator, identity: identity, devices: devices)
            let verifying = record
            let healthy = try repair.restartHoldingLease(device: device, handle: handle, verify: {
                try verify(device: device, expected: expected, record: verifying)
            }, beforeCleanup: {
                let audit = activity()
                guard !audit.isIncomplete, (audit.nativeClients ?? []).isEmpty,
                      !audit.activities.contains(where: { $0.deviceIDs.isEmpty || $0.deviceIDs.contains(id) }) else {
                    throw DeviceManagementError.unsettled("native activity changed before automatic cleanup")
                }
            })
            guard healthy, try inspect(), let final = try devices.inventory().first(where: { $0.id == id }), device.matches(final), final.state == "Shutdown",
                  try !devices.pairedDeviceIDs().contains(id),
                  try crashes.reasons().filter({ $0.kind == .criticalInfrastructure && $0.trigger.deviceID == id }).allSatisfy({ expected.contains($0) }) else {
                throw DeviceManagementError.failed("service restart did not pass verification")
            }
            var resolved = true
            for reason in expected { if try !crashes.resolveInfrastructure(reason) { resolved = false } }
            guard resolved else { throw DeviceManagementError.failed("new crash evidence arrived during verification") }
            record.state = .recovered
            record.detail = "Restart verified: stable services for 120 seconds, no critical recurrence, final shutdown confirmed. Apple runtime faults can recur."
        } catch {
            let failure = String(String(describing: error).prefix(300))
            record.state = FileManager.default.fileExists(atPath: paths.deviceRecovery.path) || record.attempts.count >= 2 ? .actionRequired : .cooldown
            if FileManager.default.fileExists(atPath: paths.deviceRecovery.path) {
                record.detail = "Recovery command did not settle. Device preserved; automatic retries paused until settlement is verified."
            } else {
                record.detail = record.attempts.count >= 2 ? "Two restart checks failed. Device preserved; next automatic attempt after the 24-hour budget resets." : "Restart verification failed. Device preserved; automatic retry waits at least ten minutes."
            }
            record.detail += " \(failure)"
        }
        record.updatedAt = now()
        try save(record)
        return try status(inventory: devices.inventory())
    }

    private func verify(device: ManagedSimulatorDevice, expected: [SimulatorCrashReason], record: AutomaticRecoveryRecord) throws {
        var progress = record
        progress.state = .verifying
        progress.detail = "Checking stable services and new crash reports for 120 booted seconds."
        try save(progress)
        var labels = ["com.apple.SpringBoard"]
        if expected.contains(where: { $0.trigger.processName == "PosterBoard" }), try SlimProfileStore(paths: paths).read()[device.id].map({ $0.complete && $0.disablesPosterBoard }) != true {
            labels.append("com.apple.PosterBoard")
        }
        var original: [String: Int32]?
        var stableSince: TimeInterval?
        let deadline = monotonicNow() + 150
        while monotonicNow() <= deadline {
            guard let current = try devices.inventory().first(where: { $0.id == device.id }), device.matches(current), current.state == "Booted",
                  try !devices.pairedDeviceIDs().contains(device.id), try inspect() else {
                throw DeviceManagementError.failed("booted state or crash-report coverage could not be verified")
            }
            let reasons = try CrashLoopStore(paths: paths).reasons().filter { $0.kind == .criticalInfrastructure && $0.trigger.deviceID == device.id }
            guard reasons.allSatisfy({ expected.contains($0) }) else { throw DeviceManagementError.failed("critical service crashed during observation") }
            let pids = try servicePIDs(device.id).filter { labels.contains($0.key) && $0.value > 0 }
            if pids.count == labels.count {
                if let original, original != pids { throw DeviceManagementError.failed("service restarted during observation") }
                if original == nil { original = pids; stableSince = monotonicNow() }
                if monotonicNow() - stableSince! >= 120 { return }
            } else if original != nil {
                throw DeviceManagementError.failed("required service stopped")
            }
            sleep(5)
        }
        throw DeviceManagementError.failed("required services were not observed for 120 seconds")
    }

    private func read() throws -> [String: AutomaticRecoveryRecord] {
        try RecoveryFile.read([String: AutomaticRecoveryRecord].self, at: url) ?? [:]
    }

    private func save(_ record: AutomaticRecoveryRecord) throws {
        try SharedStateLock.withLock(paths) {
            var records = try read()
            records[record.deviceID] = record
            try RecoveryFile.write(records, at: url)
        }
    }
}
