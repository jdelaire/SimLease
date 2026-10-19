import XCTest
@testable import SimLeaseCore

final class SimulatorShutdownServiceTests: XCTestCase {
    func testShutsDownOnlyDevicesWithoutVisibleUse() throws {
        let f = try ShutdownFixture()
        defer { f.remove() }
        let free = f.add("Free"), paired = f.add("Paired"), queued = f.add("Queued"), targeted = f.add("Targeted"), off = f.add("Off", state: "Shutdown")
        f.devices.paired = [paired]
        try f.store.writeWaiter(LeaseWaiter(id: "waiter", pid: getpid(), waitingSince: Date(), cwd: "/tmp", project: "Set", command: [], source: .codex, threadID: nil, threadTitle: "Set UI", deviceIDs: [queued.lowercased()]))
        f.report = SimulatorActivityReport(activities: [SimulatorActivity(process: ProcessReference(pid: 7, startMicroseconds: 1), tool: "xcodebuild", kind: .unmanaged, deviceIDs: [targeted])])

        let results = try f.service.shutdown(deviceIDs: [free, paired, queued, targeted, off, "99999999-9999-4999-8999-999999999999"])

        let outcomes = Dictionary(uniqueKeysWithValues: results.map { ($0.deviceID, $0.outcome) })
        XCTAssertEqual(outcomes[free], .shutdown)
        XCTAssertEqual(outcomes[off], .alreadyShutdown)
        XCTAssertEqual([paired, queued, targeted, "99999999-9999-4999-8999-999999999999"].map { outcomes[$0] }, Array(repeating: .refused, count: 4))
        XCTAssertEqual(f.devices.shutdowns, [free])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceShutdown.path))
    }

    func testUnknownTargetProcessRefusesEveryDevice() throws {
        let f = try ShutdownFixture()
        defer { f.remove() }
        let id = f.add("Free")
        f.report = SimulatorActivityReport(activities: [SimulatorActivity(process: ProcessReference(pid: 7, startMicroseconds: 1), tool: "xcodebuild", kind: .targetUnknown, deviceIDs: [])])
        XCTAssertEqual(try f.service.shutdown(deviceIDs: [id]).first?.outcome, .refused)
        f.report = SimulatorActivityReport(uninspectedProcessCount: 1)
        XCTAssertEqual(try f.service.shutdown(deviceIDs: [id]).first?.outcome, .refused)
        XCTAssertTrue(f.devices.shutdowns.isEmpty)
    }

    func testReapShutsDownExpiredBlockedAndOverflowWarmDevicesOnly() throws {
        let f = try ShutdownFixture()
        defer { f.remove() }
        let now = Date()
        let expired = f.add("Expired"), blocked = f.add("Blocked"), newest = f.add("Newest"), newer = f.add("Newer"), oldest = f.add("Oldest"), gone = f.add("Gone", state: "Shutdown")
        let warm = WarmDeviceStore(paths: f.paths)
        try warm.add([expired], since: now.addingTimeInterval(-WarmDeviceStore.idleLimit - 1))
        try warm.add([blocked, oldest], since: now.addingTimeInterval(-120))
        try warm.add([newer], since: now.addingTimeInterval(-60))
        try warm.add([newest, gone], since: now.addingTimeInterval(-30))
        try CrashLoopStore(paths: f.paths).blockInfrastructureFailure(deviceID: blocked)

        let results = try XCTUnwrap(f.service.reap(now: now))

        XCTAssertEqual(Set(results.filter { $0.outcome == .shutdown }.map(\.deviceID)), [expired, blocked, oldest])
        XCTAssertEqual(Set(try warm.read().keys), [newest, newer])
        XCTAssertEqual(f.devices.devices[newest]?.state, "Booted")
    }

    func testReapNeverWaitsForABusyLane() throws {
        let f = try ShutdownFixture()
        defer { f.remove() }
        let id = f.add("Warm")
        try WarmDeviceStore(paths: f.paths).add([id], since: Date.distantPast)
        let holder = try XCTUnwrap(f.coordinator.tryAcquire(identity: f.identity))
        defer { holder.release() }
        XCTAssertNil(try f.service.reap())
        XCTAssertTrue(f.devices.shutdowns.isEmpty)
    }

    func testBusyLaneNeverMutates() throws {
        let f = try ShutdownFixture(timing: LeaseTiming(timeout: .milliseconds(300), reportInterval: .seconds(30), pollInterval: .milliseconds(20)))
        defer { f.remove() }
        let id = f.add("Free")
        let holder = try XCTUnwrap(f.coordinator.tryAcquire(identity: f.identity))
        defer { holder.release() }
        XCTAssertThrowsError(try f.service.shutdown(deviceIDs: [id]))
        XCTAssertTrue(f.devices.shutdowns.isEmpty)
    }

    func testUncertainShutdownKeepsPartialResultsAndQuarantinesUntilSameDeviceIsRetried() throws {
        let f = try ShutdownFixture()
        defer { f.remove() }
        let ids = [f.add("First"), f.add("Second"), f.add("Third")].sorted()
        f.devices.unsettled = ids[1]

        XCTAssertEqual(try f.service.shutdown(deviceIDs: ids).map(\.outcome), [.shutdown, .unresolved])
        XCTAssertEqual(f.devices.devices[ids[2]]?.state, "Booted")
        XCTAssertThrowsError(try f.coordinator.tryAcquire(identity: f.identity))
        XCTAssertEqual(try f.coordinator.status().state, .metadataError)
        XCTAssertThrowsError(try f.service.shutdown(deviceIDs: [ids[2]]))
        XCTAssertEqual(f.devices.devices[ids[2]]?.state, "Booted")

        XCTAssertEqual(try f.service.shutdown(deviceIDs: [ids[1], ids[2]]).map(\.outcome), [.shutdown, .shutdown])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceShutdown.path))
        XCTAssertEqual(try f.coordinator.status().state, .free)
    }

    func testFailedShutdownClearsJournalOnlyWhenStateIsUnchanged() throws {
        let f = try ShutdownFixture()
        defer { f.remove() }
        let unchanged = f.add("Unchanged"), changed = f.add("Changed")
        f.devices.failing = [unchanged: nil]
        XCTAssertEqual(try f.service.shutdown(deviceIDs: [unchanged]).map(\.outcome), [.refused])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceShutdown.path))

        f.devices.failing = [changed: "Shutting Down"]
        XCTAssertEqual(try f.service.shutdown(deviceIDs: [changed]).map(\.outcome), [.unresolved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.deviceShutdown.path))
    }
}

private final class ShutdownFixture: @unchecked Sendable {
    let paths: LeasePaths
    let store: MetadataStore
    let devices = ShutdownDevices()
    let identity: LeaseIdentity
    let coordinator: LeaseCoordinator
    var report = SimulatorActivityReport()
    var service: SimulatorShutdownService!

    init(timing: LeaseTiming = .production) throws {
        paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store = try MetadataStore(paths: paths)
        identity = LeaseIdentity(pid: getpid(), cwd: paths.root.path, project: "SimLease", command: [], source: .terminal, threadID: nil, threadTitle: "Shut down simulators")
        coordinator = LeaseCoordinator(paths: paths, store: store, timing: timing)
        service = SimulatorShutdownService(paths: paths, coordinator: coordinator, identity: identity, devices: devices, activity: { [unowned self] in self.report })
    }

    func add(_ name: String, state: String = "Booted") -> String {
        let id = UUID().uuidString
        devices.devices[id] = ManagedSimulatorDevice(id: id, name: name, deviceType: "type", runtime: "runtime", dataPath: "/Devices/\(id)/data", state: state, available: true)
        return id
    }

    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}

private final class ShutdownDevices: SimulatorDeviceManaging, @unchecked Sendable {
    var devices = [String: ManagedSimulatorDevice]()
    var paired = Set<String>()
    var unsettled: String?
    var failing = [String: String?]()
    var shutdowns = [String]()

    func inventory() throws -> [ManagedSimulatorDevice] { Array(devices.values) }
    func pairedDeviceIDs() throws -> Set<String> { paired }
    func create(name: String, deviceType: String, runtime: String) throws -> String { throw DeviceManagementError.failed("unsupported") }
    func bootAndWait(_ id: String) throws { throw DeviceManagementError.failed("unsupported") }
    func shutdown(_ id: String) throws {
        if unsettled == id {
            unsettled = nil
            throw DeviceManagementError.unsettled("shutdown timed out")
        }
        if let state = failing[id] {
            if let state { devices[id]?.state = state }
            throw DeviceManagementError.failed("simctl failed")
        }
        devices[id]?.state = "Shutdown"
        shutdowns.append(id)
    }
    func delete(_ id: String) throws { throw DeviceManagementError.failed("unsupported") }
}
