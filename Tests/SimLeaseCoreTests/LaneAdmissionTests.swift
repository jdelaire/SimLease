import XCTest
@testable import SimLeaseCore

final class LaneAdmissionTests: XCTestCase {
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"

    func testDisjointDevicesShareTheMachineWhileSameDeviceWaits() throws {
        let f = try LaneFixture(maxLanes: 2, gateOpen: true)
        defer { f.remove() }
        let first = try XCTUnwrap(f.coordinator.tryAcquire(identity: f.identity, request: LaneRequest(deviceIDs: [a], exclusive: false, workspaceKey: "/one")))
        defer { first.release() }
        try f.clearAdmissionSpacing()
        XCTAssertNil(try f.coordinator.tryAcquire(identity: f.identity, request: LaneRequest(deviceIDs: [a], exclusive: false, workspaceKey: "/two")))
        XCTAssertNil(try f.coordinator.tryAcquire(identity: f.identity, request: LaneRequest(deviceIDs: [b], exclusive: false, workspaceKey: "/one")))
        let other = LeaseIdentity(pid: getppid(), cwd: f.identity.cwd, project: "Other", command: [], source: .terminal, threadID: nil, threadTitle: nil)
        let second = try XCTUnwrap(f.coordinator.tryAcquire(identity: other, request: LaneRequest(deviceIDs: [b], exclusive: false, workspaceKey: "/two")))
        defer { second.release() }
        XCTAssertEqual([first.lanes, second.lanes], [[0], [1]])
        XCTAssertNil(try f.coordinator.tryAcquire(identity: f.identity))
        XCTAssertEqual(try f.coordinator.status().lanes?.map(\.lane), [0, 1])
    }

    func testClosedGateOrSingleLaneConfigKeepsSecondJobWaiting() throws {
        for (lanes, open) in [(2, false), (1, true)] {
            let f = try LaneFixture(maxLanes: lanes, gateOpen: open)
            defer { f.remove() }
            let first = try XCTUnwrap(f.coordinator.tryAcquire(identity: f.identity, request: LaneRequest(deviceIDs: [a], exclusive: false)))
            try f.clearAdmissionSpacing()
            XCTAssertNil(try f.coordinator.tryAcquire(identity: f.identity, request: LaneRequest(deviceIDs: [b], exclusive: false, workspaceKey: "/other")))
            first.release()
        }
    }

    func testExclusiveWorkWaitsForEveryLaneAndBlocksNewLanes() throws {
        let f = try LaneFixture(maxLanes: 2, gateOpen: true)
        defer { f.remove() }
        let exclusive = try XCTUnwrap(f.coordinator.tryAcquire(identity: f.identity))
        XCTAssertEqual(exclusive.lanes, [0, 1, 2])
        XCTAssertNil(try f.coordinator.tryAcquire(identity: f.identity, request: LaneRequest(deviceIDs: [a], exclusive: false)))
        XCTAssertEqual(try f.coordinator.status().lanes?.first?.exclusive, true)
        exclusive.release()
        let single = try XCTUnwrap(f.coordinator.tryAcquire(identity: f.identity, request: LaneRequest(deviceIDs: [a], exclusive: false)))
        defer { single.release() }
        XCTAssertNil(try f.coordinator.tryAcquire(identity: f.identity))
    }

    func testUnfinishedRecordKeepsReservingItsDevicesInItsLane() throws {
        let f = try LaneFixture(maxLanes: 2, gateOpen: false)
        defer { f.remove() }
        let dead = SimulatorTaskRecord(token: "dead", owner: ProcessReference(pid: 999_999, startMicroseconds: 1), deviceIDs: [a], ownedDeviceIDs: [a], phase: .running)
        try SimulatorTaskStore(paths: f.paths.lane(1)).write(dead)
        let handle = try XCTUnwrap(f.coordinator.tryAcquire(identity: f.identity, allowUnfinishedTask: true, request: LaneRequest(deviceIDs: [a], exclusive: false)))
        defer { handle.release() }
        XCTAssertEqual(handle.lanes, [1])
    }

    func testGateClosesUnderPressureAndReopensOnlyAfterRecovery() {
        var state = HeadroomGate.State()
        let start = Date(timeIntervalSince1970: 1_000)
        func sample(_ free: Int, idle: UInt64) -> HeadroomSample {
            HeadroomSample(memoryFreePercent: free, compressorBytes: 0, swapoutBytes: 0, idleTicks: idle, totalTicks: idle * 2, load: 2, cpus: 10)
        }
        XCTAssertEqual(HeadroomGate.evaluate(&state, sample: sample(60, idle: 100), now: start).reason, "measuring headroom")
        XCTAssertEqual(HeadroomGate.evaluate(&state, sample: sample(60, idle: 150), now: start.addingTimeInterval(10)).reason, "measuring headroom")
        XCTAssertTrue(HeadroomGate.evaluate(&state, sample: sample(60, idle: 200), now: start.addingTimeInterval(40)).open)
        var busyDisk = state
        let heavy = HeadroomSample(memoryFreePercent: 60, compressorBytes: 0, swapoutBytes: 0, idleTicks: 250, totalTicks: 500, load: 400, cpus: 10)
        XCTAssertTrue(HeadroomGate.evaluate(&busyDisk, sample: heavy, now: start.addingTimeInterval(45)).open)
        XCTAssertEqual(HeadroomGate.evaluate(&state, sample: sample(39, idle: 300), now: start.addingTimeInterval(50)).reason, "memory 39% free")
        XCTAssertFalse(HeadroomGate.evaluate(&state, sample: sample(60, idle: 400), now: start.addingTimeInterval(90)).open)
        XCTAssertTrue(HeadroomGate.evaluate(&state, sample: sample(60, idle: 500), now: start.addingTimeInterval(180)).open)
        state.lastAdmissionAt = start.addingTimeInterval(170)
        XCTAssertEqual(HeadroomGate.evaluate(&state, sample: sample(60, idle: 600), now: start.addingTimeInterval(190)).reason, "spacing admissions")
    }
}

private final class LaneFixture {
    let paths: LeasePaths
    let identity: LeaseIdentity
    let coordinator: LeaseCoordinator

    init(maxLanes: Int, gateOpen: Bool) throws {
        paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let store = try MetadataStore(paths: paths)
        try LaneConfig.write(LaneConfig(maxLanes: maxLanes), paths: paths)
        let free = gateOpen ? 80 : 10
        var state = HeadroomGate.State()
        state.sample = HeadroomSample(memoryFreePercent: free, compressorBytes: 0, swapoutBytes: 0, idleTicks: 0, totalTicks: 0, load: 1, cpus: 10)
        state.sampledAt = Date().addingTimeInterval(-40)
        try RecoveryFile.write(state, at: paths.gate)
        let gate = HeadroomGate(paths: paths, sampler: { HeadroomSample(memoryFreePercent: free, compressorBytes: 0, swapoutBytes: 0, idleTicks: 900, totalTicks: 1000, load: 1, cpus: 10) })
        identity = LeaseIdentity(pid: getpid(), cwd: paths.root.path, project: "Lanes", command: [], source: .terminal, threadID: nil, threadTitle: nil)
        coordinator = LeaseCoordinator(paths: paths, store: store, gate: gate)
    }

    func clearAdmissionSpacing() throws {
        var state = try XCTUnwrap(RecoveryFile.read(HeadroomGate.State.self, at: paths.gate))
        state.lastAdmissionAt = nil
        try RecoveryFile.write(state, at: paths.gate)
    }

    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}
