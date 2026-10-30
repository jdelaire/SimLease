import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class AutomaticRecoveryTests: XCTestCase {
    func testVerifiedRestartResolvesOnlyExpectedInfrastructure() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        let result = try f.service().maintain()
        XCTAssertEqual(result.recoveries.first?.state, .recovered, result.recoveries.first?.detail ?? "")
        XCTAssertEqual(f.devices.operations, ["boot", "shutdown"])
        XCTAssertEqual(f.time.elapsed, 120)
        XCTAssertNoThrow(try f.crashes.requireHealthy([f.id]))
        XCTAssertTrue(try f.crashes.read().acknowledgments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
    }

    func testCrashAtNinetySecondsFailsAndBudgetSurvivesNewWorkerAndReports() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        f.time.onSleep = { if f.time.elapsed == 90 { try! f.block(incident: "recurrence") } }
        XCTAssertEqual(try f.service().maintain().recoveries.first?.state, .cooldown)
        XCTAssertEqual(f.devices.operations, ["boot", "shutdown"])
        _ = try f.service().maintain()
        XCTAssertEqual(f.devices.operations.count, 2)
        f.time.elapsed += 601
        f.time.onSleep = nil
        f.devices.failBoot = true
        _ = try f.service().maintain()
        f.time.elapsed += 601
        XCTAssertEqual(try f.service().maintain().recoveries.first?.state, .actionRequired)
        XCTAssertEqual(f.devices.operations, ["boot", "shutdown", "boot", "shutdown"])
        XCTAssertThrowsError(try f.crashes.requireHealthy([f.id]))
    }

    func testBusyPairedBorrowedLowHeadroomAndIncompleteAuditNeverMutate() throws {
        for condition in ["busy", "paired", "borrowed", "headroom", "audit", "native"] {
            let f = try AutomaticFixture()
            defer { f.remove() }
            try f.block()
            var handle: LeaseHandle?
            if condition == "busy" { handle = try f.coordinator.tryAcquire(identity: f.identity) }
            defer { handle?.release() }
            if condition == "paired" { f.devices.paired = [f.id] }
            if condition == "borrowed" { f.devices.device.state = "Booted" }
            if condition == "headroom" { f.canBoot = false }
            if condition == "audit" { f.audit = SimulatorActivityReport(uninspectedProcessCount: 1) }
            if condition == "native" { f.audit = SimulatorActivityReport(nativeClients: [SimulatorNativeClient(process: try .current(), role: .deviceHub, bound: false)]) }
            _ = try f.service().maintain()
            XCTAssertTrue(f.devices.operations.isEmpty, condition)
        }
    }

    func testReaperLockAndChangedFingerprintPreventCommands() throws {
        for condition in ["reaper", "fingerprint"] {
            let f = try AutomaticFixture()
            defer { f.remove() }
            try f.block()
            var lock: Int32?
            if condition == "reaper" { lock = try HostLaneLock.acquire(url: f.paths.reapLock) }
            defer { if let lock { HostLaneLock.release(url: f.paths.reapLock, descriptor: lock) } }
            if condition == "fingerprint" {
                f.devices.failBoot = true
                _ = try f.service().maintain()
                f.devices.operations.removeAll()
                f.time.elapsed += 601
                f.devices.device.name = "Changed device"
            }
            _ = try f.service().maintain()
            XCTAssertTrue(f.devices.operations.isEmpty)
        }
    }

    func testMissingServiceAndPendingEvidenceCannotCertifyRecovery() throws {
        for condition in ["missing", "backlog"] {
            let f = try AutomaticFixture()
            defer { f.remove() }
            try f.block()
            if condition == "missing" { f.pids = ["com.apple.SpringBoard": 12] }
            if condition == "backlog" { f.evidenceComplete = false }
            _ = try f.service().maintain()
            XCTAssertThrowsError(try f.crashes.requireHealthy([f.id]), condition)
            XCTAssertFalse(try f.crashes.read().acknowledgments[f.id] != nil)
        }
    }

    func testSlimProfileWithoutPosterBoardNeedsOnlySpringBoard() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        f.pids = ["com.apple.SpringBoard": 12]
        try SlimProfileStore(paths: f.paths).set(f.id, SlimProfile(keep: [], disabledCount: 1, appliedAt: f.time.now, complete: true))
        let result = try f.service().maintain()
        XCTAssertEqual(result.recoveries.first?.state, .recovered, result.recoveries.first?.detail ?? "")
        XCTAssertNoThrow(try f.crashes.requireHealthy([f.id]))
    }

    func testPairingChangedDuringObservationProtectsDeviceFromCleanup() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        f.time.onSleep = { if f.time.elapsed == 5 { f.devices.paired = [f.id] } }
        _ = try f.service().maintain()
        XCTAssertEqual(f.devices.operations, ["boot"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
        XCTAssertThrowsError(try f.crashes.requireHealthy([f.id]))
    }

    func testNewNativeActivityPreventsAutomaticCleanup() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        f.time.onSleep = { if f.time.elapsed == 5 { f.audit = SimulatorActivityReport(nativeClients: [SimulatorNativeClient(process: try! .current(), role: .deviceHub, bound: false)]) } }
        _ = try f.service().maintain()
        XCTAssertEqual(f.devices.operations, ["boot"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
    }

    func testUncertainProbeOrInventoryKeepsTransactionAndDeviceRunning() throws {
        for condition in ["probe", "inventory"] {
            let f = try AutomaticFixture()
            defer { f.remove() }
            try f.block()
            if condition == "probe" { f.probeUncertain = true }
            if condition == "inventory" { f.devices.inventoryUncertainAfterBoot = true }
            _ = try? f.service().maintain()
            XCTAssertEqual(f.devices.operations, ["boot"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
        }
    }

    func testBudgetChangedBeforeAcquisitionCannotBeOverwrittenByStaleCandidate() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        f.devices.beforeInventory = { count in
            if count == 2 {
                let record = AutomaticRecoveryRecord(deviceID: f.id, state: .cooldown, detail: "Another worker attempted recovery.", attempts: [f.time.now.addingTimeInterval(-60), f.time.now.addingTimeInterval(-30)], updatedAt: f.time.now)
                try RecoveryFile.write([f.id: record], at: f.paths.root.appendingPathComponent("automatic-recovery.json"))
            }
        }
        _ = try f.service().maintain()
        XCTAssertTrue(f.devices.operations.isEmpty)
        XCTAssertEqual(try f.service().status().recoveries.first?.attempts.count, 2)
    }

    func testPairedFirstDeviceDoesNotStarveAnotherEligibleDevice() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        let other = "22222222-2222-4222-8222-222222222222"
        f.devices.extra = ManagedSimulatorDevice(id: other, name: "Second", deviceType: "type", runtime: "runtime", dataPath: "/Devices/\(other)/data", state: "Shutdown", available: true)
        f.devices.paired = [f.id]
        _ = try f.crashes.ingest([SimulatorCrashReport(incidentID: "other", deviceID: other, occurredAt: f.time.now, launchedAt: f.time.now, signature: "poster", processName: "PosterBoard", isCriticalSystemService: true, kind: .criticalInfrastructure)], now: f.time.now)
        _ = try f.service().maintain()
        XCTAssertEqual(f.devices.bootIDs, [other])
        XCTAssertThrowsError(try f.crashes.requireHealthy([f.id]))
        XCTAssertNoThrow(try f.crashes.requireHealthy([other]))
    }

    func testUncertainCommandKeepsJournalAndNeverAutomaticallySettles() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        f.devices.uncertainBoot = true
        _ = try f.service().maintain()
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
        _ = try? f.service().maintain()
        XCTAssertEqual(f.devices.operations, ["boot"])
    }

    func testMissingDeviceBecomesHistoryOnlyWithSuccessfulInventory() throws {
        let f = try AutomaticFixture()
        defer { f.remove() }
        try f.block()
        let service = f.service()
        XCTAssertEqual(try service.status(inventory: []).recoveries.first?.state, .history)
        XCTAssertEqual(try service.status().recoveries.first?.state, .waiting)
        XCTAssertThrowsError(try f.crashes.requireHealthy([f.id]))
    }
}

private final class AutomaticTime: @unchecked Sendable {
    var elapsed: TimeInterval = 0
    var onSleep: (() -> Void)?
    var now: Date { Date(timeIntervalSince1970: 1_700_000_000 + elapsed) }
    func sleep(_ seconds: TimeInterval) { elapsed += seconds; onSleep?() }
}

private final class AutomaticFixture: @unchecked Sendable {
    let id = "11111111-1111-4111-8111-111111111111"
    let paths: LeasePaths
    let identity: LeaseIdentity
    let coordinator: LeaseCoordinator
    let crashes: CrashLoopStore
    let time = AutomaticTime()
    let devices: AutomaticDevices
    var canBoot = true
    var audit = SimulatorActivityReport()
    var pids: [String: Int32] = ["com.apple.SpringBoard": 12, "com.apple.PosterBoard": 13]
    var evidenceComplete = true
    var probeUncertain = false
    init() throws {
        paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        identity = LeaseIdentity(pid: getpid(), cwd: paths.root.path, project: "Automatic recovery", command: [], source: .terminal, threadID: nil, threadTitle: nil)
        coordinator = LeaseCoordinator(paths: paths, store: try MetadataStore(paths: paths))
        crashes = CrashLoopStore(paths: paths)
        devices = AutomaticDevices(id: id)
    }
    func service() -> AutomaticRecoveryService {
        AutomaticRecoveryService(paths: paths, coordinator: coordinator, identity: identity, devices: devices,
            activity: { self.audit }, canBoot: { self.canBoot }, servicePIDs: { _ in if self.probeUncertain { throw DeviceManagementError.unsettled("probe outcome unknown") }; return self.pids },
            inspect: { self.evidenceComplete }, now: { self.time.now }, monotonicNow: { self.time.elapsed }, sleep: { self.time.sleep($0) })
    }
    func block(incident: String = "first") throws {
        _ = try crashes.ingest([SimulatorCrashReport(incidentID: incident, deviceID: id, occurredAt: time.now, launchedAt: time.now, signature: "poster", processName: "PosterBoard", isCriticalSystemService: true, kind: .criticalInfrastructure)], now: time.now)
    }
    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}

private final class AutomaticDevices: SimulatorDeviceManaging, @unchecked Sendable {
    var device: ManagedSimulatorDevice
    var paired = Set<String>()
    var extra: ManagedSimulatorDevice?
    var bootIDs = [String]()
    var inventoryUncertainAfterBoot = false
    var beforeInventory: ((Int) throws -> Void)?
    var inventoryCount = 0
    var operations = [String]()
    var failBoot = false
    var uncertainBoot = false
    init(id: String) { device = ManagedSimulatorDevice(id: id, name: "Persistent", deviceType: "type", runtime: "runtime", dataPath: "/Devices/\(id)/data", state: "Shutdown", available: true) }
    func inventory() throws -> [ManagedSimulatorDevice] {
        inventoryCount += 1
        try beforeInventory?(inventoryCount)
        if inventoryUncertainAfterBoot && !bootIDs.isEmpty { throw DeviceManagementError.unsettled("inventory outcome unknown") }
        return [device] + (extra.map { [$0] } ?? [])
    }
    func pairedDeviceIDs() throws -> Set<String> { paired }
    func bootAndWait(_ id: String) throws {
        operations.append("boot")
        bootIDs.append(id)
        if id == device.id { device.state = "Booted" } else { extra?.state = "Booted" }
        if uncertainBoot { throw DeviceManagementError.unsettled("unknown boot result") }
        if failBoot { throw DeviceManagementError.failed("failed boot") }
    }
    func shutdown(_ id: String) throws { operations.append("shutdown"); if id == device.id { device.state = "Shutdown" } else { extra?.state = "Shutdown" } }
    func create(name: String, deviceType: String, runtime: String) throws -> String { XCTFail("automatic recovery must not create devices"); return "" }
    func delete(_ id: String) throws { XCTFail("automatic recovery must not delete devices") }
}
