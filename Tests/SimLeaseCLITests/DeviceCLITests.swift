import Foundation
import XCTest
import SimLeaseCore
@testable import SimLeaseCLI

final class DeviceCLITests: XCTestCase {
    func testUnreadableReportsCannotStarveOlderCriticalEvidenceAcrossProcesses() throws {
        let f = try DeviceCLIFixture()
        defer { f.remove() }
        try f.writeCriticalReport()
        for index in 0..<64 {
            let url = f.reports.appendingPathComponent("unreadable-\(index).ips")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60 + Double(index)), .posixPermissions: 0], ofItemAtPath: url.path)
        }
        XCTAssertEqual(f.call(["status", "--json"]), 0)
        XCTAssertTrue(try CrashLoopStore(paths: f.paths).read().blocks.isEmpty)
        XCTAssertEqual(f.call(["status", "--json"]), 0)
        XCTAssertThrowsError(try CrashLoopStore(paths: f.paths).requireHealthy([f.device]))
    }
    func testStatusAndDoctorQuarantineCriticalCrashWithoutChangingActiveTask() throws {
        for command in ["status", "doctor"] {
            let f = try DeviceCLIFixture()
            defer { f.remove() }
            try f.writeCriticalReport()
            let record = SimulatorTaskRecord(token: "active", owner: try ProcessReference.current(), deviceIDs: [f.device], ownedDeviceIDs: [], phase: .running)
            try SimulatorTaskStore(paths: f.paths).write(record)
            XCTAssertEqual(f.call([command, "--json"]), 0)
            let blocks = try XCTUnwrap(try f.output()["crashBlocks"] as? [[String: Any]])
            XCTAssertEqual(blocks.first?["deviceID"] as? String, f.device)
            XCTAssertEqual(blocks.first?["processName"] as? String, "PosterBoard")
            XCTAssertEqual(try SimulatorTaskStore(paths: f.paths).read(), record)
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), "Shutdown")
        }
    }

    func testScanProgressSurvivesStatusProcessesAndReachesOlderEvidence() throws {
        let f = try DeviceCLIFixture()
        defer { f.remove() }
        try f.writeCriticalReport()
        for index in 0..<70 {
            let url = f.reports.appendingPathComponent("invalid-\(index).ips")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60 + Double(index))], ofItemAtPath: url.path)
        }
        XCTAssertEqual(f.call(["status", "--json"]), 0)
        XCTAssertTrue(try CrashLoopStore(paths: f.paths).read().blocks.isEmpty)
        XCTAssertEqual(f.call(["status", "--json"]), 0)
        XCTAssertThrowsError(try CrashLoopStore(paths: f.paths).requireHealthy([f.device]))
        let history = f.paths.root.appendingPathComponent("crash-history.json")
        let before = try FileManager.default.attributesOfItem(atPath: history.path)[.modificationDate] as? Date
        XCTAssertEqual(f.call(["status", "--json"]), 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: history.path)[.modificationDate] as? Date, before)
    }

    func testAuditedStatusPreservesQuarantinedDeviceReservationAndLaneDiagnostics() throws {
        let f = try DeviceCLIFixture()
        defer { f.remove() }
        let record = SimulatorTaskRecord(token: "unresolved", owner: try ProcessReference.current(), deviceIDs: [f.device], ownedDeviceIDs: [f.device], phase: .quarantined)
        try SimulatorTaskStore(paths: f.paths).write(record)

        XCTAssertEqual(f.call(["status", "--json", "--audit", "--devices"]), 0)
        let status = try JSONDecoder.simLease.decode(LeaseStatus.self, from: Data(contentsOf: f.outputFile))

        XCTAssertEqual(status.state, .metadataError)
        XCTAssertEqual(status.lanes, [])
        XCTAssertEqual(status.laneErrors?.map(\.lane), [0])
        XCTAssertEqual(status.laneErrors?.first?.phase, .quarantined)
        XCTAssertEqual(status.laneErrors?.first?.deviceIDs, [f.device])
        XCTAssertEqual(status.devices?.first?.reservation, .owned)
        XCTAssertEqual(try SimulatorTaskStore(paths: f.paths).read(), record)
    }

    func testCreateRepairAndStatusUseManagedDeviceService() throws {
        let f = try DeviceCLIFixture()
        defer { f.remove() }
        XCTAssertEqual(f.call(["device", "create", "--name", "Disposable Check", "--type", f.type, "--runtime", f.runtime, "--disposable"]), 0)
        XCTAssertEqual(try f.output()["deviceID"] as? String, f.device)
        XCTAssertEqual(f.call(["device", "repair", "--device", f.device]), 0)
        XCTAssertEqual(try f.output()["state"] as? String, "healthy")
        XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), "Shutdown")
        try CrashLoopStore(paths: f.paths).blockInfrastructureFailure(deviceID: f.device)
        XCTAssertEqual(f.call(["status", "--json"]), 0)
        XCTAssertEqual((try f.output()["crashBlocks"] as? [[String: Any]])?.first?["deviceID"] as? String, f.device)
    }

    func testStatusDevicesReportsLeaseReservation() throws {
        let f = try DeviceCLIFixture()
        defer { f.remove() }
        XCTAssertEqual(f.call(["device", "create", "--name", "Disposable Check", "--type", f.type, "--runtime", f.runtime, "--disposable"]), 0)
        let handle = try XCTUnwrap(LeaseCoordinator(paths: f.paths, store: MetadataStore(paths: f.paths)).tryAcquire(identity: LeaseIdentity(pid: getpid(), cwd: "/tmp/App", project: "App", command: ["xcodebuild", "test"], source: .terminal, threadID: nil, threadTitle: "UI tests")))
        defer { handle.release() }
        try SimulatorTaskStore(paths: f.paths).write(SimulatorTaskRecord(token: "test", owner: try ProcessReference.current(), deviceIDs: [f.device], ownedDeviceIDs: [f.device], phase: .running))
        XCTAssertEqual(f.call(["status", "--json", "--devices"]), 0)
        let devices = try XCTUnwrap(try f.output()["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.map { $0["id"] as? String }, [f.device])
        XCTAssertEqual(devices.first?["reservation"] as? String, "owned")
        XCTAssertEqual(devices.first?["runtime"] as? String, "iOS 27.2")
    }

    func testAcknowledgeClearsCrashBlockWithoutTheLane() throws {
        let f = try DeviceCLIFixture()
        defer { f.remove() }
        try CrashLoopStore(paths: f.paths).blockInfrastructureFailure(deviceID: f.device)
        let holder = try XCTUnwrap(LeaseCoordinator(paths: f.paths, store: MetadataStore(paths: f.paths)).tryAcquire(identity: LeaseIdentity(pid: getppid(), cwd: "/tmp", project: "Busy", command: [], source: .terminal, threadID: nil, threadTitle: nil)))
        defer { holder.release() }
        XCTAssertEqual(f.call(["device", "acknowledge", "--device", f.device.lowercased()]), 0)
        XCTAssertEqual(try f.output()["acknowledged"] as? Bool, true)
        XCTAssertTrue(try CrashLoopStore(paths: f.paths).read().blocks.isEmpty)
    }

    func testDeviceRecoveryCannotNestInsideOwnedJob() throws {
        let f = try DeviceCLIFixture()
        defer { f.remove() }
        let record = SimulatorTaskRecord(token: "test", owner: try ProcessReference.current(), deviceIDs: [f.device], ownedDeviceIDs: [f.device], phase: .running)
        try SimulatorTaskStore(paths: f.paths).write(record)
        XCTAssertEqual(f.call(["device", "repair", "--device", f.device]), 74)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.deviceRecovery.path))
    }
}

private struct DeviceCLIFixture {
    let paths: LeasePaths
    let state: URL
    let outputFile: URL
    let manager: ProcessSimulatorDeviceManager
    let device = "11111111-1111-4111-8111-111111111111"
    let type = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
    let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
    var reports: URL { paths.root.appendingPathComponent("reports") }

    init() throws {
        paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try MetadataStore(paths: paths)
        state = paths.root.appendingPathComponent("state")
        outputFile = paths.root.appendingPathComponent("output")
        try Data("Shutdown".utf8).write(to: state)
        let created = paths.root.appendingPathComponent("created")
        let inventory = paths.root.appendingPathComponent("inventory")
        let object: [String: Any] = ["devices": [runtime: [["udid": device, "name": "Disposable Check", "state": "__STATE__", "deviceTypeIdentifier": type, "dataPath": "/Devices/\(device)/data", "isAvailable": true]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: inventory)
        let tool = paths.root.appendingPathComponent("xcrun")
        let script = """
        #!/bin/sh
        case "$2" in
          create) /usr/bin/touch "$CREATED"; printf '%s\\n' '\(device)' ;;
          list)
            if [ "$3" = pairs ]; then printf '%s' '{"pairs":{}}'
            elif [ -f "$CREATED" ]; then state=$(/bin/cat "$STATE"); /usr/bin/sed "s/__STATE__/$state/g" "$INVENTORY"
            else printf '%s' '{"devices":{}}'; fi ;;
          boot) printf Booted > "$STATE" ;;
          bootstatus) exit 0 ;;
          shutdown) printf Shutdown > "$STATE" ;;
          *) exit 7 ;;
        esac
        """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        manager = ProcessSimulatorDeviceManager(environment: ["STATE": state.path, "CREATED": created.path, "INVENTORY": inventory.path], xcrunURL: tool)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    }

    func call(_ arguments: [String]) -> Int32 {
        let output = outputFile
        return SimLeaseCLI.run(arguments: ["simlease"] + arguments, environment: [:], configuration: CLIConfiguration(paths: paths, timing: .production, standardOutput: { try? Data($0.utf8).write(to: output) }, standardError: { _ in }, deviceManager: manager, crashReportDirectory: reports))
    }
    func writeCriticalReport() throws {
        let body: [String: Any] = [
            "incident": "system", "procName": "PosterBoard", "captureTime": "2026-10-25 16:31:36.4964 +0700", "procLaunch": "2026-10-25 16:31:29.6029 +0700",
            "procPath": "/Volumes/VOLUME/*/PosterBoard.app/PosterBoard", "parentProc": "launchd_sim",
            "coalitionName": "com.apple.CoreSimulator.SimDevice.\(device)", "bundleInfo": ["CFBundleIdentifier": "com.apple.PosterBoard"],
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"], "faultingThread": 0,
            "threads": [["frames": [["symbol": "-[PRPosterDescriptor _initWithPath:].cold.1", "imageIndex": 0]]]],
            "usedImages": [["name": "PosterBoard", "uuid": "build"]],
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: reports.appendingPathComponent("critical.ips"))
    }
    func output() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outputFile)) as? [String: Any]) }
    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}
