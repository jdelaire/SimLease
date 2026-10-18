import Foundation
import XCTest
@testable import SimLeaseCore

final class SimulatorActivityAuditTests: XCTestCase {
    let device = "11111111-1111-4111-8111-111111111111"

    func testDedicatedNativeHelpersAreDiscoverableWithoutBecomingActivityAlerts() {
        let hub = process(30, tool: "T3 Code (Nightly)", arguments: ["/tools/node_modules/expo-device-hub/dist/server/cli.mjs", "--host", "127.0.0.1"])
        let daemon = process(31, tool: "T3 Code (Nightly)", arguments: ["/tools/node_modules/agent-device/dist/src/internal/daemon.js"])
        let client = process(32, tool: "node", arguments: ["/tools/node_modules/agent-device/dist/bin/agent-device.mjs", "devices"])
        let broad = process(33, tool: "T3 Code (Nightly)", arguments: ["/app/server.mjs"])
        let report = SimulatorActivityAudit.evaluate(processes: [hub, daemon, client, broad], lease: free, task: nil)
        XCTAssertTrue(report.activities.isEmpty)
        XCTAssertEqual(report.nativeClients?.map(\.process.pid), [30, 31])
        XCTAssertEqual(report.nativeClients?.map(\.role), [.deviceHub, .agentDeviceDaemon])
        XCTAssertTrue(report.nativeClients?.allSatisfy { !$0.bound } == true)
        let owner = process(20, tool: "simlease", arguments: [])
        var task = SimulatorTaskRecord(token: "scope", owner: owner.process, deviceIDs: [device], ownedDeviceIDs: [], phase: .running)
        task.externalSessionID = UUID().uuidString
        task.nativeClients = [daemon.process]
        let held = SimulatorActivityAudit.evaluate(processes: [owner, hub, daemon], lease: leased(owner: 20, source: .nativeTool), task: task)
        XCTAssertEqual(held.nativeClients?.map(\.bound), [false, true])
    }

    func testUnleasedMutationsAreReportedWithoutInventoryOrIdleServices() {
        let processes = [
            process(10, tool: "simctl", arguments: ["boot", device]),
            process(11, tool: "simctl", arguments: ["list", "devices", "--json"]),
            process(12, tool: "CoreSimulatorService", arguments: []),
            process(13, tool: "node", arguments: ["/tools/agent-device.mjs", "daemon", "start"]),
        ]
        let report = SimulatorActivityAudit.evaluate(processes: processes, lease: free, task: nil)
        XCTAssertEqual(report.activities.map(\.process.pid), [10])
        XCTAssertEqual(report.activities.first?.kind, .unmanaged)
    }

    func testManagedDescendantsNeedBothHeldLaneAndExactOwnerIdentity() {
        let owner = process(20, tool: "simlease", arguments: [])
        let child = process(21, parent: 20, tool: "simctl", arguments: ["boot", device])
        let task = SimulatorTaskRecord(token: "scope", owner: owner.process, deviceIDs: [device], ownedDeviceIDs: [device], phase: .running)
        XCTAssertTrue(SimulatorActivityAudit.evaluate(processes: [owner, child], lease: leased(owner: 20), task: task).activities.isEmpty)
        XCTAssertEqual(SimulatorActivityAudit.evaluate(processes: [owner, child], lease: free, task: task).activities.count, 1)
        let reused = process(20, start: 999, tool: "simlease", arguments: [])
        XCTAssertEqual(SimulatorActivityAudit.evaluate(processes: [reused, child], lease: leased(owner: 20), task: task).activities.count, 1)
    }

    func testManualReservationDoesNotClaimVerifiedOwnership() {
        let owner = process(20, tool: "simlease", arguments: [])
        let task = SimulatorTaskRecord(token: "scope", owner: owner.process, deviceIDs: [device], ownedDeviceIDs: [device], phase: .running)
        let matching = process(21, tool: "simctl", arguments: ["boot", device])
        let other = process(22, tool: "simctl", arguments: ["boot", "22222222-2222-4222-8222-222222222222"])
        let report = SimulatorActivityAudit.evaluate(processes: [owner, matching, other], lease: leased(owner: 20, source: .manualXcode), task: task)
        XCTAssertEqual(report.activities.map(\.kind), [.reservedNative, .unmanaged])
    }

    func testBoundNativeRootsRequireExactIdentityAndValidDevicePosition() {
        let owner = process(20, tool: "simlease", arguments: [])
        let root = process(30, tool: "node", arguments: ["hub.mjs"])
        let allowed = process(31, parent: 30, tool: "simctl", arguments: ["boot", device])
        let alias = process(32, parent: 30, tool: "simctl", arguments: ["spawn", "booted", "/bin/echo", device])
        var task = SimulatorTaskRecord(token: "scope", owner: owner.process, deviceIDs: [device], ownedDeviceIDs: [device], phase: .running)
        task.externalSessionID = UUID().uuidString
        task.nativeClients = [root.process]
        let lease = leased(owner: 20, source: .nativeTool)
        let report = SimulatorActivityAudit.evaluate(processes: [owner, root, allowed, alias], lease: lease, task: task)
        XCTAssertEqual(report.activities.map(\.process.pid), [32])
        task.nativeClients = [ProcessReference(pid: 30, startMicroseconds: 999)]
        XCTAssertEqual(SimulatorActivityAudit.evaluate(processes: [owner, root, allowed], lease: lease, task: task).activities.count, 1)
    }

    func testNodeClientsAreVisibleButAndroidPhysicalAndMacOSTargetsAreExcluded() {
        let processes = [
            process(10, tool: "node", arguments: ["/tools/agent-device.mjs", "--platform", "ios", "--udid", device, "snapshot"]),
            process(11, tool: "T3 Code (Nightly)", arguments: ["/tools/agent-device.mjs", "--platform", "android", "snapshot"]),
            process(12, tool: "agent-device", arguments: ["--platform", "ios", "--udid", "00008130-00123456789ABCDE", "snapshot"]),
            process(13, tool: "xcodebuild", arguments: ["test", "-destination", "platform=macOS"]),
            process(14, tool: "agent-device", arguments: ["snapshot"]),
            process(15, tool: "xcodebuild", arguments: ["test", "-sdk", "iphoneos"]),
            process(16, tool: "xcodebuild", arguments: ["-showBuildSettings", "-sdk", "iphonesimulator"]),
            process(17, tool: "xcodebuild", arguments: ["-showdestinations", "-destination", "platform=iOS Simulator"]),
            process(18, tool: "xcodebuild", arguments: ["-list", "-sdk", "iphonesimulator"]),
        ]
        let report = SimulatorActivityAudit.evaluate(processes: processes, lease: free, task: nil)
        XCTAssertEqual(report.activities.map(\.process.pid), [10, 14])
        XCTAssertEqual(report.activities.map(\.kind), [.unmanaged, .targetUnknown])
    }

    func testActivityIdentityDeduplicatesAndChangesWhenPIDIsReused() throws {
        let first = process(10, tool: "simctl", arguments: ["boot", device])
        let report = SimulatorActivityAudit.evaluate(processes: [first, first], lease: free, task: nil)
        XCTAssertEqual(report.activities.count, 1)
        let reused = SimulatorActivityAudit.evaluate(processes: [process(10, start: 999, tool: "simctl", arguments: ["boot", device])], lease: free, task: nil)
        XCTAssertNotEqual(try XCTUnwrap(report.activities.first).id, try XCTUnwrap(reused.activities.first).id)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("arguments"))
    }

    func testProcessReuseDuringCaptureCannotBorrowPreviousArguments() {
        let reader = ChangingProcessReader()
        let report = SimulatorActivityAudit(reader: reader).scan(lease: free, task: nil)
        XCTAssertTrue(report.activities.isEmpty)
        XCTAssertEqual(report.uninspectedProcessCount, 1)
        XCTAssertTrue(report.isIncomplete)
    }

    func testInspectionFailureCannotLookLikeCompleteCoverage() {
        let report = SimulatorActivityAudit(reader: FailingProcessReader()).scan(lease: free, task: nil)
        XCTAssertTrue(report.isIncomplete)
        XCTAssertNotNil(report.error)
    }

    func testUnverifiableLiveProcessesRemainIncompleteButExitedProcessesDoNot() {
        let live = SimulatorActivityAudit(reader: UnverifiableProcessReader(exited: false)).scan(lease: free, task: nil)
        XCTAssertEqual(live.uninspectedProcessCount, 2)
        let exited = SimulatorActivityAudit(reader: UnverifiableProcessReader(exited: true)).scan(lease: free, task: nil)
        XCTAssertEqual(exited.uninspectedProcessCount, 1)
    }

    var free: LeaseStatus { LeaseStatus(state: .free, owner: nil, waiters: [], error: nil) }

    func leased(owner: Int32, source: LeaseSource = .terminal) -> LeaseStatus {
        LeaseStatus(state: .leased, owner: LeaseOwner(pid: owner, acquiredAt: Date(timeIntervalSince1970: 100), cwd: "/project", project: "App", command: [], source: source, threadID: nil, threadTitle: nil), waiters: [], error: nil)
    }

    func process(_ pid: Int32, parent: Int32 = 1, start: UInt64 = 1, tool: String, arguments: [String]) -> SimulatorProcessSnapshot {
        SimulatorProcessSnapshot(process: ProcessReference(pid: pid, startMicroseconds: start), parentPID: parent, executable: "/tools/\(tool)", arguments: [tool] + arguments)
    }
}

private struct ChangingProcessReader: SimulatorProcessReading {
    func references() throws -> SimulatorProcessInventory { SimulatorProcessInventory(references: [ProcessReference(pid: 10, startMicroseconds: 1)]) }
    func details(for reference: ProcessReference) throws -> SimulatorProcessSnapshot {
        SimulatorProcessSnapshot(process: reference, parentPID: 1, executable: "/tools/simctl", arguments: ["simctl", "boot", "booted"])
    }
    func current(pid: Int32) -> ProcessReference? { ProcessReference(pid: pid, startMicroseconds: 2) }
    func hasExited(pid: Int32) -> Bool { false }
}

private struct FailingProcessReader: SimulatorProcessReading {
    func references() throws -> SimulatorProcessInventory { throw NSError(domain: "inspection", code: 1) }
    func details(for reference: ProcessReference) throws -> SimulatorProcessSnapshot { throw NSError(domain: "inspection", code: 1) }
    func current(pid: Int32) -> ProcessReference? { nil }
    func hasExited(pid: Int32) -> Bool { false }
}

private struct UnverifiableProcessReader: SimulatorProcessReading {
    let exited: Bool
    func references() throws -> SimulatorProcessInventory {
        SimulatorProcessInventory(references: [ProcessReference(pid: 10, startMicroseconds: 1)], uninspectedProcessCount: 1)
    }
    func details(for reference: ProcessReference) throws -> SimulatorProcessSnapshot {
        SimulatorProcessSnapshot(process: reference, parentPID: 1, executable: "/tools/simctl", arguments: ["simctl", "boot", "booted"])
    }
    func current(pid: Int32) -> ProcessReference? { nil }
    func hasExited(pid: Int32) -> Bool { exited }
}
