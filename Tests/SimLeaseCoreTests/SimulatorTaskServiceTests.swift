import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class SimulatorTaskServiceTests: XCTestCase {
    func testCrashLimitStopsOwnedJobEvenWhenTerminationHandlerExitsZero() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = SimulatorTaskService(paths: fixture.paths, devices: fixture.devices, crashReportDirectory: directory)
        let started = Date()
        let code = try service.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap 'exit 0' TERM; printf Booted > \"$1\"; n=0; while [ \"$n\" -lt 100 ]; do /bin/sleep 0.05; n=$((n+1)); done", "job", fixture.devices.path(fixture.owned).path],
            deviceIDs: [fixture.owned], keepRunning: false, environment: [:], identity: fixture.identity,
            onStarted: { _ in
                try writeCrashReports(directory: directory, device: fixture.owned)
            }
        )
        XCTAssertNotEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Shutdown")
        XCTAssertNil(try fixture.store.read())
        XCTAssertThrowsError(try CrashLoopStore(paths: fixture.paths).requireHealthy([fixture.owned]))
    }

    func testBlockedNativeScopeCanSettleWithoutKillingSharedClient() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        let crashes = CrashLoopStore(paths: fixture.paths)
        let settlements = NativeSettlementStore(paths: fixture.paths)
        let code = try fixture.service.run(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], deviceIDs: [fixture.owned],
            keepRunning: false, environment: [:], identity: fixture.identity, externalSessionID: UUID().uuidString,
            onStarted: { record in
                let now = Date()
                _ = try crashes.ingest([
                    SimulatorCrashReport(incidentID: "one", deviceID: fixture.owned, occurredAt: now, launchedAt: now, signature: "same", processName: "App"),
                    SimulatorCrashReport(incidentID: "two", deviceID: fixture.owned, occurredAt: now, launchedAt: now, signature: "same", processName: "App"),
                ], now: now)
                try settlements.acknowledge(record)
            }
        )
        XCTAssertEqual(code, 0)
        XCTAssertNil(try fixture.store.read())
        XCTAssertThrowsError(try crashes.requireHealthy([fixture.owned]))
    }

    func testUnsettledNativeWorkCannotShutdownOrRecover() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        let code = try fixture.service.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf Booted > \"$1\"", "job", fixture.devices.path(fixture.owned).path],
            deviceIDs: [fixture.owned], keepRunning: false, environment: [:], identity: fixture.identity,
            externalSessionID: UUID().uuidString
        )
        XCTAssertEqual(code, 74)
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Booted")
        XCTAssertEqual(try fixture.store.read()?.phase, .quarantined)
        XCTAssertThrowsError(try fixture.service.recover(identity: fixture.identity))
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Booted")
    }

    func testDurableNativeAcknowledgmentSurvivesCrashBeforeJournalSettlement() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        var record = SimulatorTaskRecord(token: UUID().uuidString, owner: ProcessReference(pid: getpid(), startMicroseconds: 1), deviceIDs: [fixture.owned], ownedDeviceIDs: [fixture.owned], phase: .running)
        record.externalSessionID = UUID().uuidString
        try fixture.store.write(record)
        try fixture.devices.set(fixture.owned, state: "Booted")
        let settlements = NativeSettlementStore(paths: fixture.paths)
        try settlements.acknowledge(record)
        try fixture.service.recover(identity: fixture.identity)
        XCTAssertNil(try fixture.store.read())
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Shutdown")
        XCTAssertFalse(try settlements.isAcknowledged(record))
    }

    func testStaleNativeAcknowledgmentCannotSettleNewTaskWithSameSessionID() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        var previous = SimulatorTaskRecord(token: UUID().uuidString, owner: ProcessReference(pid: getpid(), startMicroseconds: 1), deviceIDs: [fixture.owned], ownedDeviceIDs: [fixture.owned], phase: .running)
        previous.externalSessionID = UUID().uuidString
        let settlements = NativeSettlementStore(paths: fixture.paths)
        try settlements.acknowledge(previous)
        var next = SimulatorTaskRecord(token: UUID().uuidString, owner: previous.owner, deviceIDs: previous.deviceIDs, ownedDeviceIDs: previous.ownedDeviceIDs, phase: .running)
        next.externalSessionID = previous.externalSessionID
        try fixture.store.write(next)
        try fixture.devices.set(fixture.owned, state: "Booted")
        XCTAssertThrowsError(try fixture.service.recover(identity: fixture.identity))
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Booted")
        XCTAssertTrue(try settlements.isAcknowledged(previous))
    }

    func testAcknowledgedNativeCleanupFailureKeepsAcknowledgmentForRetry() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        fixture.devices.failShutdown = true
        let settlements = NativeSettlementStore(paths: fixture.paths)
        let code = try fixture.service.run(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], deviceIDs: [fixture.owned],
            keepRunning: false, environment: [:], identity: fixture.identity, externalSessionID: UUID().uuidString,
            onStarted: { try settlements.acknowledge($0) }
        )
        XCTAssertEqual(code, 74)
        let record = try XCTUnwrap(fixture.store.read())
        XCTAssertEqual(record.externalWorkSettled, true)
        XCTAssertTrue(try settlements.isAcknowledged(record))
        XCTAssertThrowsError(try NativeSessionController(paths: fixture.paths, tasks: fixture.service).finish(id: record.externalSessionID!, identity: fixture.identity))
        fixture.devices.failShutdown = false
        try fixture.service.recover(identity: fixture.identity)
        XCTAssertNil(try fixture.store.read())
        XCTAssertFalse(try settlements.isAcknowledged(record))
    }

    func testDeletedOwnedDeviceIsAlreadySettled() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        let code = try fixture.service.run(
            executable: URL(fileURLWithPath: "/bin/rm"), arguments: [fixture.devices.path(fixture.owned).path],
            deviceIDs: [fixture.owned], keepRunning: false, environment: [:], identity: fixture.identity
        )
        XCTAssertEqual(code, 0)
        XCTAssertNil(try fixture.devices.states()[fixture.owned])
        XCTAssertNil(try fixture.store.read())
    }

    func testFailedJobShutsDownOwnedDeviceAndPreservesBorrowedDevice() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        try fixture.devices.set(fixture.borrowed, state: "Booted")

        let code = try fixture.run(exit: 7, deviceIDs: [fixture.owned, fixture.borrowed])

        XCTAssertEqual(code, 7)
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Shutdown")
        XCTAssertEqual(try fixture.devices.state(fixture.borrowed), "Booted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.task.path))
    }

    func testKeepRunningExplicitlyRetainsStartedDevice() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }

        XCTAssertEqual(try fixture.run(exit: 0, keepRunning: true), 0)
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Booted")
    }

    func testShutdownFailureQuarantinesAndBlocksNextJob() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        fixture.devices.failShutdown = true

        XCTAssertEqual(try fixture.run(exit: 0), 74)
        XCTAssertEqual(try fixture.store.read()?.phase, .quarantined)
        let marker = fixture.root.appendingPathComponent("must-not-run")
        XCTAssertThrowsError(try fixture.service.run(
            executable: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path], deviceIDs: [], keepRunning: false,
            environment: [:], identity: fixture.identity
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCleanupFailurePreservesExistingJobFailure() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        fixture.devices.failShutdown = true

        XCTAssertEqual(try fixture.run(exit: 9), 9)
        XCTAssertEqual(try fixture.store.read()?.phase, .quarantined)
    }

    func testRecoveryRetriesQuarantinedShutdownBeforeNextJob() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        fixture.devices.failShutdown = true
        XCTAssertEqual(try fixture.run(exit: 0), 74)
        fixture.devices.failShutdown = false

        try fixture.service.recover(identity: fixture.identity)

        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Shutdown")
        XCTAssertNil(try fixture.store.read())
    }

    func testRecoveryDoesNotTakeOverLiveTaskOwner() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        let record = SimulatorTaskRecord(
            token: UUID().uuidString,
            owner: try ProcessReference.current(),
            deviceIDs: [fixture.owned], ownedDeviceIDs: [fixture.owned],
            phase: .running
        )
        try fixture.store.write(record)
        try fixture.devices.set(fixture.owned, state: "Booted")

        XCTAssertThrowsError(try fixture.service.recover(identity: fixture.identity))
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Booted")
    }

    func testRecoveryHandlesReusedOwnerPIDWithoutSignallingCurrentProcess() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        let record = SimulatorTaskRecord(
            token: UUID().uuidString,
            owner: ProcessReference(pid: getpid(), startMicroseconds: 1),
            deviceIDs: [fixture.owned], ownedDeviceIDs: [fixture.owned],
            phase: .running
        )
        try fixture.store.write(record)
        try fixture.devices.set(fixture.owned, state: "Booted")

        try fixture.service.recover(identity: fixture.identity)

        XCTAssertNil(try fixture.store.read())
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Shutdown")
    }

    func testUnverifiedChildGroupPreventsDeviceShutdown() throws {
        let fixture = try TaskFixture()
        defer { fixture.remove() }
        var record = SimulatorTaskRecord(
            token: UUID().uuidString,
            owner: ProcessReference(pid: getpid(), startMicroseconds: 1),
            deviceIDs: [fixture.owned], ownedDeviceIDs: [fixture.owned],
            phase: .running
        )
        record.child = ProcessReference(pid: getpgrp(), startMicroseconds: 1)
        try fixture.store.write(record)
        try fixture.devices.set(fixture.owned, state: "Booted")

        XCTAssertThrowsError(try fixture.service.recover(identity: fixture.identity))
        XCTAssertEqual(try fixture.devices.state(fixture.owned), "Booted")
    }
}

private func writeCrashReports(directory: URL, device: String) throws {
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX")
    date.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS Z"
    usleep(2_000)
    let now = date.string(from: Date())
    for id in ["one", "two"] {
        let body: [String: Any] = [
            "incident": id, "procName": "App", "captureTime": now, "procLaunch": now,
            "procPath": "/Users/USER/Library/Developer/CoreSimulator/Devices/\(device)/data/App.app/App",
            "coalitionName": "com.apple.CoreSimulator.SimDevice.\(device)",
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"], "faultingThread": 0,
            "threads": [["frames": [["symbol": "crash", "imageIndex": 0]]]],
            "usedImages": [["name": "App", "uuid": "build"]],
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: directory.appendingPathComponent(id + ".ips"))
    }
}

private final class TaskFixture {
    let root: URL
    let paths: LeasePaths
    let devices: FileDevices
    let store: SimulatorTaskStore
    let service: SimulatorTaskService
    let identity: LeaseIdentity
    let owned = "11111111-1111-4111-8111-111111111111"
    let borrowed = "22222222-2222-4222-8222-222222222222"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = LeasePaths(root: root.appendingPathComponent("cache"))
        _ = try MetadataStore(paths: paths)
        devices = try FileDevices(root: root.appendingPathComponent("devices"))
        try devices.set(owned, state: "Shutdown")
        try devices.set(borrowed, state: "Shutdown")
        store = SimulatorTaskStore(paths: paths)
        service = SimulatorTaskService(paths: paths, devices: devices)
        identity = LeaseIdentity(pid: getpid(), cwd: root.path, project: "Task", command: ["task"], source: .terminal, threadID: nil, threadTitle: nil)
    }

    func run(exit: Int, deviceIDs: [String]? = nil, keepRunning: Bool = false) throws -> Int32 {
        try service.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf Booted > \"$1\"; exit \"$2\"", "job", devices.path(owned).path, String(exit)],
            deviceIDs: deviceIDs ?? [owned], keepRunning: keepRunning,
            environment: [:], identity: identity
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class FileDevices: SimulatorDeviceControlling, @unchecked Sendable {
    let root: URL
    var failShutdown = false

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func path(_ id: String) -> URL { root.appendingPathComponent(id) }
    func state(_ id: String) throws -> String { try String(contentsOf: path(id), encoding: .utf8) }
    func set(_ id: String, state: String) throws { try Data(state.utf8).write(to: path(id)) }

    func states() throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) })
    }

    func shutdown(_ id: String) throws {
        guard FileManager.default.fileExists(atPath: path(id).path) else {
            throw SimulatorTaskError.unknownDevice(id)
        }
        if failShutdown { throw NSError(domain: "simulator", code: 1) }
        try set(id, state: "Shutdown")
    }
}
