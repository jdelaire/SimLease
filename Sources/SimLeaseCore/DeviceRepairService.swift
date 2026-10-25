import Foundation

public struct ManagedSimulatorDevice: Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public let deviceType: String
    public let runtime: String
    public let dataPath: String
    public var state: String
    public let available: Bool

    func matches(_ other: ManagedSimulatorDevice) -> Bool {
        id == other.id && name == other.name && deviceType == other.deviceType && runtime == other.runtime && dataPath == other.dataPath
    }
}

public protocol SimulatorDeviceManaging: Sendable {
    func inventory() throws -> [ManagedSimulatorDevice]
    func pairedDeviceIDs() throws -> Set<String>
    func create(name: String, deviceType: String, runtime: String) throws -> String
    func bootAndWait(_ id: String) throws
    func shutdown(_ id: String) throws
    func delete(_ id: String) throws
}

public enum DeviceManagementError: Error, CustomStringConvertible {
    case failed(String)
    case unsettled(String)

    public var description: String {
        switch self {
        case .failed(let detail): detail
        case .unsettled(let detail): "device command outcome is uncertain: \(detail); confirm prior recovery work has finished before resuming with --settled"
        }
    }
}

public struct DeviceRepairResult: Codable, Sendable {
    public let state: String
    public let deviceID: String
    public let replacedDeviceID: String?
    public let crashBlocked: Bool
}

struct DisposableRegistry: Codable {
    var devices = [String: ManagedSimulatorDevice]()
    var replacements = [String: String]()
}

struct DeviceRepairTransaction: Codable {
    let id: String
    var owner: ProcessReference
    let original: ManagedSimulatorDevice?
    let name: String
    let deviceType: String
    let runtime: String
    var replacementID: String?
    var replacement: ManagedSimulatorDevice?
    var replacementVerified = false
    var deletingOriginal = false
    var pendingAction: String?
    var originalBootAttempts = 0
    var originalBootFailures = 0
    var originalBootHealthy = false
}

public struct DeviceRepairService: Sendable {
    private let paths: LeasePaths
    private let coordinator: LeaseCoordinator
    private let identity: LeaseIdentity
    private let devices: any SimulatorDeviceManaging
    private var registryURL: URL { paths.root.appendingPathComponent("disposable-devices.json") }

    public init(paths: LeasePaths, coordinator: LeaseCoordinator, identity: LeaseIdentity, devices: any SimulatorDeviceManaging) {
        self.paths = paths
        self.coordinator = coordinator
        self.identity = identity
        self.devices = devices
    }

    public func create(name: String, deviceType: String, runtime: String) throws -> DeviceRepairResult {
        let handle = try coordinator.acquire(identity: identity)
        defer { handle.release() }
        var registry = try readRegistry()
        var transaction = DeviceRepairTransaction(id: UUID().uuidString, owner: try ProcessReference.current(), original: nil, name: name, deviceType: deviceType, runtime: runtime)
        try save(transaction)
        let id = try perform(&transaction, "create") { try devices.create(name: name, deviceType: deviceType, runtime: runtime) }
        guard let valid = UUID(uuidString: id)?.uuidString else { throw DeviceManagementError.unsettled("create returned an invalid UUID") }
        transaction.replacementID = valid
        try save(transaction)
        let device = try find(valid)
        guard device.state == "Shutdown", device.name == name, device.deviceType == deviceType, device.runtime == runtime else {
            throw DeviceManagementError.failed("new disposable device did not match requested configuration")
        }
        registry.devices[valid] = device
        try RecoveryFile.write(registry, at: registryURL)
        try removeTransaction()
        return DeviceRepairResult(state: "created", deviceID: valid, replacedDeviceID: nil, crashBlocked: false)
    }

    public func repair(deviceID: String, settled: Bool = false, acknowledgeCrashes: Bool = false) throws -> DeviceRepairResult {
        let handle = try coordinator.acquire(identity: identity, allowUnfinishedRepair: true)
        defer { handle.release() }
        var registry = try readRegistry()
        var transaction: DeviceRepairTransaction
        if var pending = try RecoveryFile.read(DeviceRepairTransaction.self, at: paths.deviceRecovery) {
            guard pending.original?.id == deviceID else {
                throw DeviceManagementError.failed("another recovery is pending; use simlease device recover --settled for interrupted device creation")
            }
            guard settled else { throw DeviceManagementError.unsettled("previous repair is unfinished") }
            try requireStoppedOwner(pending.owner)
            pending.owner = try ProcessReference.current()
            pending.pendingAction = nil
            transaction = pending
            try save(transaction)
        } else {
            let original = try find(deviceID)
            try requireShutdownUnpaired(original)
            if let known = registry.devices[deviceID], !known.matches(original) {
                throw DeviceManagementError.failed("disposable provenance changed; device is protected")
            }
            transaction = DeviceRepairTransaction(id: UUID().uuidString, owner: try ProcessReference.current(), original: original, name: original.name, deviceType: original.deviceType, runtime: original.runtime)
            try save(transaction)
        }
        let original = transaction.original!
        if transaction.replacementID == nil {
            let current = try find(deviceID)
            guard original.matches(current), current.available else { throw DeviceManagementError.failed("device configuration changed or runtime unavailable") }
            if current.state != "Shutdown" {
                try perform(&transaction, "shutdown") { try devices.shutdown(deviceID) }
                try requireShutdownUnpaired(find(deviceID))
            }
            if transaction.originalBootHealthy {
                try completeHealthy(deviceID, acknowledgeCrashes: acknowledgeCrashes)
                try removeTransaction()
                return try result(state: "healthy", id: deviceID)
            }
            while transaction.originalBootAttempts < 2 {
                transaction.originalBootAttempts += 1
                try save(transaction)
                if try checkBoot(deviceID, transaction: &transaction) {
                    try completeHealthy(deviceID, acknowledgeCrashes: acknowledgeCrashes)
                    try removeTransaction()
                    return try result(state: "healthy", id: deviceID)
                }
            }
            guard transaction.originalBootFailures == 2 else {
                throw DeviceManagementError.unsettled("boot retry budget exhausted without two verified failures; abandon settled recovery without deletion")
            }
            try CrashLoopStore(paths: paths).blockInfrastructureFailure(deviceID: deviceID)
            guard let known = registry.devices[deviceID], known.matches(original) else {
                try removeTransaction()
                throw DeviceManagementError.failed("simulator failed both boot checks; persistent device preserved")
            }
            try requireShutdownUnpaired(find(deviceID))
            let name = "\(original.name) recovery \(transaction.id.prefix(8))"
            let id = try perform(&transaction, "create replacement") {
                try devices.create(name: name, deviceType: original.deviceType, runtime: original.runtime)
            }
            guard let valid = UUID(uuidString: id)?.uuidString, valid != original.id else {
                throw DeviceManagementError.unsettled("replacement identity is invalid")
            }
            transaction.replacementID = valid
            try save(transaction)
        }
        let replacementID = transaction.replacementID!
        let selected = try find(replacementID)
        if let expected = transaction.replacement {
            guard expected.matches(selected) else { throw DeviceManagementError.failed("replacement provenance changed; original deletion refused") }
        } else {
            let expectedName = "\(original.name) recovery \(transaction.id.prefix(8))"
            guard selected.name == expectedName, selected.deviceType == original.deviceType, selected.runtime == original.runtime else {
                throw DeviceManagementError.failed("replacement configuration does not match creation intent")
            }
            transaction.replacement = selected
            try save(transaction)
        }
        if !transaction.replacementVerified {
            guard try checkBoot(replacementID, transaction: &transaction) else {
                throw DeviceManagementError.failed("replacement failed its boot check; original preserved and recovery quarantined")
            }
            transaction.replacementVerified = true
            try save(transaction)
        }
        let replacement = try find(replacementID)
        guard transaction.replacement?.matches(replacement) == true, replacement.deviceType == original.deviceType, replacement.runtime == original.runtime else {
            throw DeviceManagementError.failed("replacement configuration changed")
        }
        try requireShutdownUnpaired(replacement)
        registry.devices[replacementID] = replacement
        try RecoveryFile.write(registry, at: registryURL)
        let inventory = try devices.inventory()
        if let current = inventory.first(where: { $0.id == original.id }) {
            guard let registered = registry.devices[original.id], registered.matches(original), original.matches(current) else {
                throw DeviceManagementError.failed("original disposable provenance changed; deletion refused")
            }
            try requireShutdownUnpaired(current)
            transaction.deletingOriginal = true
            try save(transaction)
            try perform(&transaction, "delete original") { try devices.delete(original.id) }
            guard try !devices.inventory().contains(where: { $0.id == original.id }) else {
                throw DeviceManagementError.unsettled("original deletion was not verified")
            }
        } else if !transaction.deletingOriginal {
            throw DeviceManagementError.failed("original disappeared before recorded deletion")
        }
        registry.devices.removeValue(forKey: original.id)
        registry.replacements[original.id] = replacementID
        try RecoveryFile.write(registry, at: registryURL)
        try CrashLoopStore(paths: paths).acknowledge(deviceID: original.id, at: Date())
        try removeTransaction()
        return try result(state: "replaced", id: replacementID, original: original.id)
    }

    public func recoverCreation(settled: Bool) throws {
        let handle = try coordinator.acquire(identity: identity, allowUnfinishedRepair: true)
        defer { handle.release() }
        guard let transaction = try RecoveryFile.read(DeviceRepairTransaction.self, at: paths.deviceRecovery) else { return }
        guard settled else { throw DeviceManagementError.unsettled("prior recovery settlement is required") }
        try requireStoppedOwner(transaction.owner)
        let ids = Set([transaction.original?.id, transaction.replacementID].compactMap { $0 })
        let inventory = try devices.inventory()
        let existing = inventory.filter { ids.contains($0.id) }
        guard existing.allSatisfy({ $0.state == "Shutdown" }) else {
            throw DeviceManagementError.unsettled("all recorded devices must be Shutdown before abandoning recovery")
        }
        let crashes = CrashLoopStore(paths: paths)
        for device in existing { try crashes.blockInfrastructureFailure(deviceID: device.id) }
        for id in ids where !existing.contains(where: { $0.id == id }) { try crashes.acknowledge(deviceID: id, at: Date()) }
        try removeTransaction()
    }

    func restartHoldingLease(device: ManagedSimulatorDevice, handle: LeaseHandle, verify: @escaping () throws -> Void, beforeCleanup: @escaping () throws -> Void) throws -> Bool {
        guard handle.paths.root.path == paths.root.path, handle.lanes.count == LeasePaths.maximumLanes,
              handle.owner.pid == identity.pid, !FileManager.default.fileExists(atPath: paths.deviceRecovery.path),
              device.matches(try find(device.id)) else {
            throw DeviceManagementError.failed("automatic recovery requires an exclusive lease and unchanged device")
        }
        try requireShutdownUnpaired(find(device.id))
        var transaction = DeviceRepairTransaction(id: UUID().uuidString, owner: try ProcessReference.current(), original: device, name: device.name, deviceType: device.deviceType, runtime: device.runtime)
        transaction.originalBootAttempts = 1
        try save(transaction)
        let healthy = try checkBoot(device.id, transaction: &transaction, verify: verify, beforeCleanup: beforeCleanup)
        try removeTransaction()
        return healthy
    }

    private func checkBoot(_ id: String, transaction: inout DeviceRepairTransaction, verify: (() throws -> Void)? = nil, beforeCleanup: (() throws -> Void)? = nil) throws -> Bool {
        var healthy = true
        var bootCompleted = false
        do {
            try perform(&transaction, "boot health check") {
                try devices.bootAndWait(id)
                bootCompleted = true
                try verify?()
            }
            if transaction.original?.id == id {
                transaction.originalBootHealthy = true
                try save(transaction)
            }
        } catch DeviceManagementError.failed {
            healthy = false
            if transaction.original?.id == id && !bootCompleted {
                transaction.originalBootFailures += 1
                try save(transaction)
            }
        }
        try beforeCleanup?()
        if verify != nil, let original = transaction.original {
            let current = try find(id)
            guard original.matches(current), current.available, ["Booted", "Shutdown"].contains(current.state), try !devices.pairedDeviceIDs().contains(id) else {
                throw DeviceManagementError.unsettled("device configuration or pairing changed before automatic cleanup")
            }
        }
        try perform(&transaction, "shutdown after health check") { try devices.shutdown(id) }
        try requireShutdownUnpaired(find(id))
        return healthy
    }

    private func completeHealthy(_ id: String, acknowledgeCrashes: Bool) throws {
        let crashes = CrashLoopStore(paths: paths)
        let signature = try crashes.read().blocks[id]?.signature
        if acknowledgeCrashes || signature == "simulator-boot-health" {
            try crashes.acknowledge(deviceID: id, at: Date())
        }
    }

    private func result(state: String, id: String, original: String? = nil) throws -> DeviceRepairResult {
        DeviceRepairResult(state: state, deviceID: id, replacedDeviceID: original, crashBlocked: try CrashLoopStore(paths: paths).read().blocks[id] != nil)
    }

    private func find(_ id: String) throws -> ManagedSimulatorDevice {
        guard let device = try devices.inventory().first(where: { $0.id == id }) else { throw SimulatorTaskError.unknownDevice(id) }
        return device
    }

    private func requireShutdownUnpaired(_ device: ManagedSimulatorDevice) throws {
        guard device.state == "Shutdown", device.available, try !devices.pairedDeviceIDs().contains(device.id) else {
            throw DeviceManagementError.failed("recovery requires an available, Shutdown, unpaired device; live and borrowed devices are protected")
        }
    }

    private func requireStoppedOwner(_ owner: ProcessReference) throws {
        let current = try ProcessReference.current()
        guard owner.state != .unknown, owner.state != .matching || owner == current else {
            throw SimulatorTaskError.unverifiedProcess(owner.pid)
        }
    }

    private func readRegistry() throws -> DisposableRegistry { try RecoveryFile.read(DisposableRegistry.self, at: registryURL) ?? DisposableRegistry() }
    private func save(_ transaction: DeviceRepairTransaction) throws { try RecoveryFile.write(transaction, at: paths.deviceRecovery) }
    private func removeTransaction() throws { try FileManager.default.removeItem(at: paths.deviceRecovery) }

    private func perform<Value>(_ transaction: inout DeviceRepairTransaction, _ action: String, body: () throws -> Value) throws -> Value {
        transaction.pendingAction = action
        try save(transaction)
        do {
            let value = try body()
            transaction.pendingAction = nil
            try save(transaction)
            return value
        } catch DeviceManagementError.failed(let detail) {
            transaction.pendingAction = nil
            try save(transaction)
            throw DeviceManagementError.failed(detail)
        }
    }
}
