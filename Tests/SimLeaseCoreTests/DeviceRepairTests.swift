import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class DeviceRepairTests: XCTestCase {
    func testHealthyPersistentDeviceRetainsIdentityAndCrashBlock() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let id = try f.addPersistent()
        try f.crashes.blockInfrastructureFailure(deviceID: id)
        let result = try f.service.repair(deviceID: id)
        XCTAssertEqual(result.deviceID, id)
        XCTAssertEqual(result.state, "healthy")
        XCTAssertEqual(f.manager.devices[id]?.state, "Shutdown")
        XCTAssertEqual(f.manager.devices.count, 1)
        XCTAssertNoThrow(try f.crashes.requireHealthy([id]))
    }

    func testUnhealthyPersistentDeviceIsNeverDeletedOrEnrolled() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let id = try f.addPersistent()
        f.manager.failingBoots.insert(id)
        XCTAssertThrowsError(try f.service.repair(deviceID: id))
        XCTAssertEqual(f.manager.bootAttempts[id], 2)
        XCTAssertEqual(f.manager.devices[id]?.state, "Shutdown")
        XCTAssertEqual(f.manager.devices.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
        XCTAssertThrowsError(try f.crashes.requireHealthy([id]))
    }

    func testDisposableReplacementIsVerifiedBeforeOriginalDeletion() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let original = try f.service.create(name: "Test", deviceType: "type", runtime: "runtime").deviceID
        f.manager.failingBoots.insert(original)
        let result = try f.service.repair(deviceID: original)
        XCTAssertEqual(result.state, "replaced")
        XCTAssertNotEqual(result.deviceID, original)
        XCTAssertNil(f.manager.devices[original])
        XCTAssertEqual(f.manager.devices[result.deviceID]?.state, "Shutdown")
        XCTAssertTrue(f.manager.deletedOnlyAfterVerifiedReplacement)
        XCTAssertNoThrow(try f.crashes.requireHealthy([original]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
    }

    func testFailedReplacementPreservesOriginalAndQuarantinesTransaction() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let original = try f.service.create(name: "Test", deviceType: "type", runtime: "runtime").deviceID
        f.manager.failEveryBoot = true
        XCTAssertThrowsError(try f.service.repair(deviceID: original))
        XCTAssertNotNil(f.manager.devices[original])
        XCTAssertEqual(f.manager.devices[original]?.state, "Shutdown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
        XCTAssertThrowsError(try f.coordinator.tryAcquire(identity: f.identity, allowUnfinishedTask: true))
    }

    func testBorrowedPairedAndChangedProvenanceDevicesCannotBeReplaced() throws {
        for condition in ["booted", "paired", "changed"] {
            let f = try RepairFixture()
            defer { f.remove() }
            let id = try f.service.create(name: "Test", deviceType: "type", runtime: "runtime").deviceID
            f.manager.failingBoots.insert(id)
            if condition == "booted" { f.manager.setState(id, "Booted") }
            if condition == "paired" { f.manager.paired.insert(id) }
            if condition == "changed" { f.manager.devices[id]?.name = "User data" }
            XCTAssertThrowsError(try f.service.repair(deviceID: id))
            XCTAssertNotNil(f.manager.devices[id])
            XCTAssertEqual(f.manager.devices.count, 1)
        }
    }

    func testAmbiguousBootTimeoutDoesNotRetryOrDeleteWithoutSettlement() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let id = try f.service.create(name: "Test", deviceType: "type", runtime: "runtime").deviceID
        f.manager.ambiguousBoot = true
        XCTAssertThrowsError(try f.service.repair(deviceID: id))
        XCTAssertEqual(f.manager.bootAttempts[id], 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
        XCTAssertThrowsError(try f.service.repair(deviceID: id))
        XCTAssertNotNil(f.manager.devices[id])
    }

    func testInterruptedDeletionRequiresSettlementAndResumesRecordedReplacement() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let original = try f.service.create(name: "Test", deviceType: "type", runtime: "runtime").deviceID
        f.manager.failingBoots.insert(original)
        f.manager.failDeletion = true
        XCTAssertThrowsError(try f.service.repair(deviceID: original))
        XCTAssertEqual(f.manager.devices.count, 2)
        f.manager.failDeletion = false
        XCTAssertThrowsError(try f.service.repair(deviceID: original))
        let result = try f.service.repair(deviceID: original, settled: true)
        XCTAssertEqual(f.manager.devices.count, 1)
        XCTAssertNil(f.manager.devices[original])
        XCTAssertEqual(f.manager.devices[result.deviceID]?.state, "Shutdown")
    }

    func testChangedReplacementFingerprintCannotAuthorizeOriginalDeletion() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let original = try f.service.create(name: "Test", deviceType: "type", runtime: "runtime").deviceID
        f.manager.failingBoots.insert(original)
        f.manager.failDeletion = true
        XCTAssertThrowsError(try f.service.repair(deviceID: original))
        let replacement = try XCTUnwrap(f.manager.devices.keys.first { $0 != original })
        f.manager.devices[replacement]?.name = "Protected data"
        f.manager.failDeletion = false
        XCTAssertThrowsError(try f.service.repair(deviceID: original, settled: true))
        XCTAssertNotNil(f.manager.devices[original])
    }

    func testHealthyBootDoesNotClearAppCrashEvidenceWithoutAcknowledgment() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let id = try f.addPersistent()
        let now = Date()
        try f.crashes.beginScope(id: "job", deviceIDs: [id], startedAt: now.addingTimeInterval(-10))
        _ = try f.crashes.ingest(["one", "two"].map {
            SimulatorCrashReport(incidentID: $0, deviceID: id, occurredAt: now, launchedAt: now, signature: "app-build", processName: "App")
        }, now: now)
        XCTAssertTrue(try f.service.repair(deviceID: id).crashBlocked)
        XCTAssertFalse(try f.service.repair(deviceID: id, acknowledgeCrashes: true).crashBlocked)
        XCTAssertEqual(try f.crashes.read().incidents.count, 2)
    }

    func testAbandoningSettledRecoveryPreservesDevicesAndBlocksReuse() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let original = try f.service.create(name: "Test", deviceType: "type", runtime: "runtime").deviceID
        f.manager.failEveryBoot = true
        XCTAssertThrowsError(try f.service.repair(deviceID: original))
        XCTAssertThrowsError(try f.service.recoverCreation(settled: false))
        try f.service.recoverCreation(settled: true)
        XCTAssertEqual(f.manager.devices.count, 2)
        XCTAssertNotNil(f.manager.devices[original])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
        for id in f.manager.devices.keys { XCTAssertThrowsError(try f.crashes.requireHealthy([id])) }
    }

    func testInterruptedBootBudgetDoesNotRestartTwoAutomaticAttempts() throws {
        let f = try RepairFixture()
        defer { f.remove() }
        let original = try f.service.create(name: "Test", deviceType: "type", runtime: "runtime").deviceID
        f.manager.failingBoots.insert(original)
        f.manager.failShutdownOnce = true
        XCTAssertThrowsError(try f.service.repair(deviceID: original))
        f.manager.setState(original, "Shutdown")
        _ = try? f.service.repair(deviceID: original, settled: true)
        XCTAssertLessThanOrEqual(f.manager.bootAttempts[original, default: 0], 2)
    }
}

private final class RepairFixture {
    let paths: LeasePaths
    let manager = RepairDevices()
    let identity: LeaseIdentity
    let coordinator: LeaseCoordinator
    let service: DeviceRepairService
    let crashes: CrashLoopStore

    init() throws {
        paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let store = try MetadataStore(paths: paths)
        identity = LeaseIdentity(pid: getpid(), cwd: paths.root.path, project: "Repair", command: [], source: .terminal, threadID: nil, threadTitle: nil)
        coordinator = LeaseCoordinator(paths: paths, store: store)
        service = DeviceRepairService(paths: paths, coordinator: coordinator, identity: identity, devices: manager)
        crashes = CrashLoopStore(paths: paths)
    }
    func addPersistent() throws -> String { try manager.create(name: "Persistent", deviceType: "type", runtime: "runtime") }
    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}

private final class RepairDevices: SimulatorDeviceManaging, @unchecked Sendable {
    var devices = [String: ManagedSimulatorDevice]()
    var paired = Set<String>()
    var failingBoots = Set<String>()
    var failEveryBoot = false
    var ambiguousBoot = false
    var failDeletion = false
    var failShutdownOnce = false
    var bootAttempts = [String: Int]()
    var healthy = Set<String>()
    var deletedOnlyAfterVerifiedReplacement = false

    func inventory() throws -> [ManagedSimulatorDevice] { Array(devices.values) }
    func pairedDeviceIDs() throws -> Set<String> { paired }
    func create(name: String, deviceType: String, runtime: String) throws -> String {
        let id = UUID().uuidString
        devices[id] = ManagedSimulatorDevice(id: id, name: name, deviceType: deviceType, runtime: runtime, dataPath: "/Devices/\(id)/data", state: "Shutdown", available: true)
        return id
    }
    func bootAndWait(_ id: String) throws {
        bootAttempts[id, default: 0] += 1
        setState(id, "Booted")
        if ambiguousBoot { throw DeviceManagementError.unsettled("boot timed out") }
        if failEveryBoot || failingBoots.contains(id) { throw DeviceManagementError.failed("boot failed") }
        healthy.insert(id)
    }
    func shutdown(_ id: String) throws {
        if failShutdownOnce {
            failShutdownOnce = false
            throw DeviceManagementError.unsettled("shutdown interrupted")
        }
        setState(id, "Shutdown")
    }
    func delete(_ id: String) throws {
        if failDeletion { throw DeviceManagementError.failed("delete failed") }
        deletedOnlyAfterVerifiedReplacement = devices.values.contains { $0.id != id && $0.state == "Shutdown" && healthy.contains($0.id) }
        devices.removeValue(forKey: id)
    }
    func setState(_ id: String, _ state: String) { devices[id]?.state = state }
}
