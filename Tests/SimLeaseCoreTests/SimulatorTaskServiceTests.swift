import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class SimulatorTaskServiceTests: XCTestCase {
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
