import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class SimulatorSlimServiceTests: XCTestCase {
    func testSlimDisablesDesiredLabelsAndRecordsProfile() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        let result = try f.service.slim(deviceID: f.id, keep: ["health"], settled: false)
        let desired = try SimulatorServiceCatalog.desired(keep: ["health"])
        XCTAssertEqual(result.state, "slimmed")
        XCTAssertEqual(result.disabledCount, desired.count)
        XCTAssertEqual(f.devices.disabled[f.id], desired)
        XCTAssertEqual(f.devices.devices[f.id]?.state, "Shutdown")
        XCTAssertEqual(try f.profiles.read()[f.id], SlimProfile(keep: ["health"], disabledCount: desired.count, appliedAt: f.date, complete: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
    }

    func testAlreadySlimDeviceIsUnchanged() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        f.devices.disabled[f.id] = try SimulatorServiceCatalog.desired(keep: [])
        XCTAssertEqual(try f.service.slim(deviceID: f.id, keep: [], settled: false).state, "unchanged")
        XCTAssertEqual(f.devices.boots, 1)
        XCTAssertEqual(f.devices.devices[f.id]?.state, "Shutdown")
    }

    func testUnslimReenablesManagedOnlyAndRemovesProfile() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        _ = try f.service.slim(deviceID: f.id, keep: [], settled: false)
        f.devices.disabled[f.id]?.insert("com.example.custom")
        XCTAssertEqual(try f.service.unslim(deviceID: f.id, settled: false).state, "restored")
        XCTAssertEqual(f.devices.disabled[f.id], ["com.example.custom"])
        XCTAssertNil(try f.profiles.read()[f.id])
    }

    func testLostOverridesFailAndLeaveIncompleteProfile() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        f.devices.dropOnReboot = true
        XCTAssertThrowsError(try f.service.slim(deviceID: f.id, keep: [], settled: false)) {
            guard case DeviceManagementError.failed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(f.devices.devices[f.id]?.state, "Shutdown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
        XCTAssertEqual(try f.profiles.read()[f.id]?.complete, false)
    }

    func testPartialTransitionFailureLeavesIncompleteProfile() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        f.devices.failingLabels["com.apple.chronod"] = 3
        XCTAssertThrowsError(try f.service.slim(deviceID: f.id, keep: [], settled: false))
        XCTAssertEqual(f.devices.devices[f.id]?.state, "Shutdown")
        XCTAssertEqual(try f.profiles.read()[f.id]?.complete, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
    }

    func testTransitionsAndReadsRetryTransientFailures() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        f.devices.failingLabels["com.apple.chronod"] = 2
        f.devices.failingReads = 2
        XCTAssertEqual(try f.service.slim(deviceID: f.id, keep: [], settled: false).state, "slimmed")
        XCTAssertTrue(f.devices.disabled[f.id]?.contains("com.apple.chronod") == true)
    }

    func testRefusesBootedPairedOldRuntimeAndBlockedSlim() throws {
        for condition in ["booted", "paired", "runtime", "blocked"] {
            let f = try SlimFixture(runtime: condition == "runtime" ? "com.apple.CoreSimulator.SimRuntime.iOS-18-4" : nil)
            defer { f.remove() }
            if condition == "booted" { f.devices.devices[f.id]?.state = "Booted" }
            if condition == "paired" { f.devices.paired.insert(f.id) }
            if condition == "blocked" { try CrashLoopStore(paths: f.paths).blockInfrastructureFailure(deviceID: f.id) }
            XCTAssertThrowsError(try f.service.slim(deviceID: f.id, keep: [], settled: false), condition)
            XCTAssertEqual(f.devices.boots, 0, condition)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path), condition)
        }
    }

    func testUnslimAllowedOnCrashBlockedDeviceAndKeepsBlock() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        f.devices.disabled[f.id] = ["com.apple.chronod"]
        try CrashLoopStore(paths: f.paths).blockInfrastructureFailure(deviceID: f.id)
        XCTAssertEqual(try f.service.unslim(deviceID: f.id, settled: false).state, "restored")
        XCTAssertNotNil(try CrashLoopStore(paths: f.paths).read().blocks[f.id])
    }

    func testInterruptedSlimRequiresSettlementAndConverges() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        f.devices.devices[f.id]?.state = "Booted"
        let device = try XCTUnwrap(f.devices.devices[f.id])
        let dead = ProcessReference(pid: Int32.max - 7, startMicroseconds: 1)
        let pending = DeviceRepairTransaction(id: "T", owner: dead, original: device, name: device.name, deviceType: device.deviceType, runtime: device.runtime, purpose: "slim")
        try RecoveryFile.write(pending, at: f.paths.deviceRecovery)
        XCTAssertThrowsError(try f.service.slim(deviceID: f.id, keep: [], settled: false)) {
            guard case DeviceManagementError.unsettled = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try f.service.slim(deviceID: f.id, keep: [], settled: true).state, "slimmed")
        XCTAssertEqual(f.devices.devices[f.id]?.state, "Shutdown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
    }

    func testRepairRefusesPendingSlimAndLegacyJournalsDecode() throws {
        let f = try SlimFixture()
        defer { f.remove() }
        let device = try XCTUnwrap(f.devices.devices[f.id])
        let dead = ProcessReference(pid: Int32.max - 7, startMicroseconds: 1)
        try RecoveryFile.write(DeviceRepairTransaction(id: "T", owner: dead, original: device, name: device.name, deviceType: device.deviceType, runtime: device.runtime, purpose: "slim"), at: f.paths.deviceRecovery)
        let repair = DeviceRepairService(paths: f.paths, coordinator: f.coordinator, identity: f.identity, devices: f.devices)
        XCTAssertThrowsError(try repair.repair(deviceID: f.id, settled: true)) {
            XCTAssertTrue(String(describing: $0).contains("slim profile change is pending"))
        }
        XCTAssertEqual(f.devices.boots, 0)
        let legacy = Data(#"{"id":"T","owner":{"pid":1,"startMicroseconds":1},"name":"n","deviceType":"t","runtime":"r","replacementVerified":false,"deletingOriginal":false,"originalBootAttempts":0,"originalBootFailures":0,"originalBootHealthy":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(DeviceRepairTransaction.self, from: legacy).purpose)
    }

    func testProfileCheckReportsDriftAndStates() throws {
        let profile = SlimProfile(keep: ["widgets"], disabledCount: 1, appliedAt: Date(), complete: true)
        var device = ManagedSimulatorDevice(id: "A", name: "n", deviceType: "t", runtime: "r", dataPath: "", state: "Booted", available: true)
        var disabled = try SimulatorServiceCatalog.desired(keep: ["widgets"])
        XCTAssertEqual(SlimProfileCheck.check(deviceID: "A", profile: profile, device: device, disabled: disabled).state, .ok)
        disabled.remove("com.apple.chronod")
        disabled.insert("com.apple.PosterBoard")
        let drift = SlimProfileCheck.check(deviceID: "A", profile: profile, device: device, disabled: disabled)
        XCTAssertEqual(drift.state, .drift)
        XCTAssertEqual(drift.reenabled, [])
        XCTAssertEqual(drift.extraDisabled, ["com.apple.PosterBoard"])
        disabled.remove("com.apple.siriactionsd")
        XCTAssertEqual(SlimProfileCheck.check(deviceID: "A", profile: profile, device: device, disabled: disabled).reenabled, ["com.apple.siriactionsd"])
        XCTAssertEqual(SlimProfileCheck.check(deviceID: "A", profile: profile, device: nil, disabled: nil).state, .missing)
        XCTAssertEqual(SlimProfileCheck.check(deviceID: "A", profile: profile, device: device, disabled: nil).state, .unreadable)
        let incomplete = SlimProfile(keep: [], disabledCount: 1, appliedAt: Date(), complete: false)
        XCTAssertEqual(SlimProfileCheck.check(deviceID: "A", profile: incomplete, device: device, disabled: []).state, .incomplete)
        device.state = "Shutdown"
        XCTAssertEqual(SlimProfileCheck.check(deviceID: "A", profile: profile, device: device, disabled: nil).state, .notBooted)
    }

    func testSlimProfileReportsWhetherPosterBoardIsDisabled() {
        XCTAssertTrue(SlimProfile(keep: [], disabledCount: 1, appliedAt: Date(), complete: true).disablesPosterBoard)
        XCTAssertFalse(SlimProfile(keep: ["widgets"], disabledCount: 1, appliedAt: Date(), complete: true).disablesPosterBoard)
    }
}

private final class SlimFixture {
    let paths: LeasePaths
    let devices = SlimDevices()
    let identity: LeaseIdentity
    let coordinator: LeaseCoordinator
    let service: SimulatorSlimService
    let profiles: SlimProfileStore
    let date = Date(timeIntervalSince1970: 1_000)
    let id = "11111111-1111-4111-8111-111111111111"

    init(runtime: String? = nil) throws {
        paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let store = try MetadataStore(paths: paths)
        identity = LeaseIdentity(pid: getpid(), cwd: paths.root.path, project: "Slim", command: [], source: .terminal, threadID: nil, threadTitle: nil)
        coordinator = LeaseCoordinator(paths: paths, store: store)
        let date = date
        service = SimulatorSlimService(paths: paths, coordinator: coordinator, identity: identity, devices: devices, launchd: devices, inspect: {}, now: { date }, delays: [0, 0, 0, 0])
        profiles = SlimProfileStore(paths: paths)
        devices.devices[id] = ManagedSimulatorDevice(id: id, name: "iPhone", deviceType: "type", runtime: runtime ?? "com.apple.CoreSimulator.SimRuntime.iOS-27-2", dataPath: "/tmp/data", state: "Shutdown", available: true)
    }

    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}

private final class SlimDevices: SimulatorDeviceManaging, SimulatorLaunchdControlling, @unchecked Sendable {
    private let lock = NSLock()
    var devices = [String: ManagedSimulatorDevice]()
    var disabled = [String: Set<String>]()
    var paired = Set<String>()
    var dropOnReboot = false
    var failingLabels = [String: Int]()
    var failingReads = 0
    var boots = 0
    private var bootBaseline = [String: Set<String>]()

    func inventory() throws -> [ManagedSimulatorDevice] { lock.withLock { Array(devices.values) } }
    func pairedDeviceIDs() throws -> Set<String> { lock.withLock { paired } }
    func create(name: String, deviceType: String, runtime: String) throws -> String { throw DeviceManagementError.failed("unsupported") }
    func delete(_ id: String) throws { throw DeviceManagementError.failed("unsupported") }

    func bootAndWait(_ id: String) throws {
        lock.withLock {
            boots += 1
            if dropOnReboot, let baseline = bootBaseline[id] { disabled[id] = baseline }
            if bootBaseline[id] == nil { bootBaseline[id] = disabled[id] ?? [] }
            devices[id]?.state = "Booted"
        }
    }

    func shutdown(_ id: String) throws { lock.withLock { devices[id]?.state = "Shutdown" } }

    func launchctl(_ deviceID: String, _ arguments: [String]) throws -> String {
        try lock.withLock {
            guard devices[deviceID]?.state == "Booted" else { throw DeviceManagementError.failed("not booted") }
            if arguments == ["print-disabled", "system"] {
                if failingReads > 0 { failingReads -= 1; throw DeviceManagementError.failed("Domain is tearing down") }
                let lines = (disabled[deviceID] ?? []).sorted().map { "\t\"\($0)\" => disabled" }
                return "disabled services = {\n" + lines.joined(separator: "\n") + "\n}\n"
            }
            let label = String(arguments[1].dropFirst("system/".count))
            if let remaining = failingLabels[label], remaining > 0 {
                failingLabels[label] = remaining - 1
                throw DeviceManagementError.failed("launchctl failed")
            }
            if arguments[0] == "disable" { disabled[deviceID, default: []].insert(label) } else { disabled[deviceID]?.remove(label) }
            return ""
        }
    }
}
