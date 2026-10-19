import Foundation
import XCTest
import SimLeaseCore
@testable import SimLeaseCLI

final class DeviceCLITests: XCTestCase {
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
    }

    func call(_ arguments: [String]) -> Int32 {
        let output = outputFile
        return SimLeaseCLI.run(arguments: ["simlease"] + arguments, environment: [:], configuration: CLIConfiguration(paths: paths, timing: .production, standardOutput: { try? Data($0.utf8).write(to: output) }, standardError: { _ in }, deviceManager: manager))
    }
    func output() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outputFile)) as? [String: Any]) }
    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}
