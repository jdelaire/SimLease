import Darwin
import Foundation
import XCTest
import SimLeaseCore

final class NativeSessionTests: XCTestCase {
    func testBoundNativeBootReusesClaimedWarmDeviceAndFinishShutsItDown() throws {
        let fixture = try NativeFixture()
        try fixture.setState("Booted")
        _ = try MetadataStore(paths: fixture.paths)
        try WarmDeviceStore(paths: fixture.paths).add([fixture.device], since: Date())
        let (keeper, ready, record) = try fixture.begin(clientPID: getpid())
        XCTAssertEqual(ready["ownedDeviceIDs"] as? [String], [fixture.device])
        XCTAssertEqual(try fixture.callShim(["simctl", "boot", fixture.device]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("native-started").path))
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
        XCTAssertTrue(try String(contentsOf: fixture.inventory, encoding: .utf8).contains("Shutdown"))
        XCTAssertTrue(try WarmDeviceStore(paths: fixture.paths).read().isEmpty)
    }
    func testCrashBlockedNativeClientCanStillShutdownAndSettle() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin(clientPID: getpid())
        try CrashLoopStore(paths: fixture.paths).blockInfrastructureFailure(deviceID: fixture.device)
        XCTAssertEqual(try fixture.callShim(["simctl", "boot", fixture.device]), 74)
        XCTAssertEqual(try fixture.callShim(["simctl", "list", "devices", "--json"]), 0)
        XCTAssertEqual(try fixture.callShim(["simctl", "shutdown", fixture.device]), 0)
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
        XCTAssertNil(try SimulatorTaskStore(paths: fixture.paths).read())
    }
    func testUnboundInventoryQueryDoesNotWaitOrShutdownInteractiveDevice() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin()
        try fixture.setState("Booted")
        XCTAssertEqual(try fixture.callShim(["simctl", "list", "devices", "--json"]), 0)
        XCTAssertTrue(try String(contentsOf: fixture.inventory, encoding: .utf8).contains("Booted"))
        XCTAssertTrue(keeper.process.isRunning)
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
        XCTAssertTrue(try String(contentsOf: fixture.inventory, encoding: .utf8).contains("Shutdown"))
    }

    func testReadySessionBlocksOtherJobsUntilSettledCleanup() throws {
        let fixture = try NativeFixture()
        let (keeper, ready, record) = try fixture.begin()
        XCTAssertEqual(ready["state"] as? String, "ready")
        XCTAssertEqual(ready["ownedDeviceIDs"] as? [String], [fixture.device])
        XCTAssertNotNil(record.child)
        let marker = fixture.root.appendingPathComponent("admitted")
        let waiting = try fixture.launch(["run", "--", "/usr/bin/touch", marker.path])
        try fixture.wait { !(try MetadataStore(paths: fixture.paths).readWaiters()).isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
        XCTAssertEqual(try fixture.exit(waiting), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBoundNativeHelperCanUseOnlyDeclaredSimulatorTargets() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin(clientPID: getpid())
        XCTAssertEqual(record.nativeClients?.first, ProcessReference.capture(pid: getpid()))
        XCTAssertEqual(try fixture.callShim(["simctl", "boot", fixture.device]), 0)
        XCTAssertEqual(try fixture.callShim(["simctl", "list", "devices", "--json"]), 0)
        XCTAssertEqual(try fixture.callShim(["simctl", "spawn", "booted", "/bin/echo", fixture.device]), 74)
        XCTAssertEqual(try fixture.callShim(["simctl", "shutdown", "all"]), 74)
        XCTAssertEqual(try fixture.callShim(["simctl", "boot", "22222222-2222-4222-8222-222222222222"]), 74)
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
    }

    func testBoundNativeLaunchOptionsPreserveTargetValidationThroughShim() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin(clientPID: getpid())
        let forwarded = fixture.root.appendingPathComponent("launch-arguments")
        let other = "22222222-2222-4222-8222-222222222222"
        for arguments in [
            ["simctl", "launch", "--terminate-running-process", fixture.device, "com.example.app"],
            ["simctl", "launch", "-w", "--console-pty", fixture.device, "com.example.app"],
            ["simctl", "launch", "--stdout", "/tmp/x", fixture.device, "com.example.app"],
            ["simctl", "launch", "--stdout", other, fixture.device, "com.example.app"],
        ] {
            XCTAssertEqual(try fixture.callShim(arguments), 0)
            XCTAssertEqual(try String(contentsOf: forwarded, encoding: .utf8), arguments.joined(separator: "\n") + "\n")
        }
        try FileManager.default.removeItem(at: forwarded)
        for arguments in [
            ["simctl", "launch", "--terminate-running-process", "booted", "com.example.app"],
            ["simctl", "launch", "--unknown-flag", fixture.device, "com.example.app"],
            ["simctl", "launch", "--terminate-running-process", other, "com.example.app"],
            ["simctl", "launch", "--stdout", fixture.device, "com.example.app"],
        ] {
            XCTAssertEqual(try fixture.callShim(arguments), 74)
            XCTAssertFalse(FileManager.default.fileExists(atPath: forwarded.path))
        }
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
    }

    func testInteractiveSessionKeepsDeviceBootedAcrossCallsAndPreservesBorrowedDevice() throws {
        let fixture = try NativeFixture()
        try fixture.setState("Booted")
        let (keeper, ready, record) = try fixture.begin(clientPID: getpid())
        XCTAssertEqual(ready["ownedDeviceIDs"] as? [String], [])
        for _ in 0..<3 {
            XCTAssertEqual(try fixture.callShim(["simctl", "io", fixture.device, "screenshot", fixture.root.appendingPathComponent("shot.png").path]), 0)
            XCTAssertTrue(try String(contentsOf: fixture.inventory, encoding: .utf8).contains("Booted"))
            XCTAssertTrue(keeper.process.isRunning)
        }
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
        XCTAssertTrue(try String(contentsOf: fixture.inventory, encoding: .utf8).contains("Booted"))
    }

    func testBoundRunnerCannotSkipDestinationValidationThroughBuildClassification() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin(clientPID: getpid())
        let marker = fixture.root.appendingPathComponent("runner-invoked")
        for arguments in [
            ["build", "-destination", "id=22222222-2222-4222-8222-222222222222"],
            ["build", "-sdk", "iphonesimulator"],
            ["build"],
            ["-runFirstLaunch", "-list"],
        ] {
            XCTAssertEqual(try fixture.callShim(arguments, tool: "xcodebuild"), 74)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
        XCTAssertEqual(try fixture.callShim(["build-for-testing", "-destination", "id=\(fixture.device)"], tool: "xcodebuild"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
    }

    func testFinishWaitsForBoundShimBeforeAcknowledgingSettlement() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin(clientPID: getpid())
        try Data().write(to: fixture.root.appendingPathComponent("block-native"))
        let client = try fixture.launch(["simctl", "boot", fixture.device], shim: true)
        try fixture.wait { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("native-started").path) }
        let finishing = try fixture.launch(["session", "finish", record.externalSessionID!, "--settled"])
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(finishing.process.isRunning)
        XCTAssertFalse(try NativeSettlementStore(paths: fixture.paths).isAcknowledged(record))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("block-native"))
        XCTAssertEqual(try fixture.exit(client), 0)
        XCTAssertEqual(try fixture.exit(finishing), 0)
        XCTAssertEqual(try fixture.exit(keeper), 0)
    }

    func testCanceledKeeperStaysBlockedUntilExplicitSettlement() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin()
        keeper.process.terminate()
        XCTAssertEqual(try fixture.exit(keeper), 143)
        XCTAssertEqual(try SimulatorTaskStore(paths: fixture.paths).read()?.phase, .quarantined)
        XCTAssertEqual(try fixture.call(["recover"]), 74)
        XCTAssertEqual(try fixture.call(["run", "--", "/usr/bin/true"]), 74)
        XCTAssertEqual(try fixture.call(["session", "finish", UUID().uuidString, "--settled"]), 74)
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertNil(try SimulatorTaskStore(paths: fixture.paths).read())
    }

    func testCrashAfterDurableAcknowledgmentCanRecover() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin()
        XCTAssertEqual(kill(keeper.process.processIdentifier, SIGSTOP), 0)
        try NativeSettlementStore(paths: fixture.paths).acknowledge(record)
        XCTAssertEqual(kill(keeper.process.processIdentifier, SIGKILL), 0)
        XCTAssertEqual(try fixture.exit(keeper), 137)
        XCTAssertNotEqual(try SimulatorTaskStore(paths: fixture.paths).read()?.externalWorkSettled, true)
        XCTAssertEqual(try fixture.call(["recover"]), 0)
        XCTAssertNil(try SimulatorTaskStore(paths: fixture.paths).read())
    }

    func testFinishReportsCleanupFailureAndRetryKeepsSameAcknowledgment() throws {
        let fixture = try NativeFixture()
        let (keeper, _, record) = try fixture.begin()
        try fixture.setState("Booted")
        try Data().write(to: fixture.failure)
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 74)
        XCTAssertEqual(try fixture.exit(keeper), 74)
        XCTAssertTrue(try NativeSettlementStore(paths: fixture.paths).isAcknowledged(record))
        try FileManager.default.removeItem(at: fixture.failure)
        XCTAssertEqual(try fixture.call(["session", "finish", record.externalSessionID!, "--settled"]), 0)
        XCTAssertNil(try SimulatorTaskStore(paths: fixture.paths).read())
    }

    func testWaiterAndOldSessionCannotControlAnotherKeeper() throws {
        let fixture = try NativeFixture()
        let (first, _, old) = try fixture.begin()
        XCTAssertEqual(try fixture.call(["__native_wait", old.externalSessionID!]), 74)
        XCTAssertEqual(try fixture.call(["session", "finish", old.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(first), 0)
        let (second, _, current) = try fixture.begin()
        XCTAssertNotEqual(old.externalSessionID, current.externalSessionID)
        XCTAssertEqual(try fixture.call(["session", "finish", old.externalSessionID!, "--settled"]), 74)
        XCTAssertTrue(second.process.isRunning)
        XCTAssertEqual(try fixture.call(["session", "finish", current.externalSessionID!, "--settled"]), 0)
        XCTAssertEqual(try fixture.exit(second), 0)
    }
}

private final class NativeFixture {
    struct Launch {
        let process: Process
        let output: URL
        let errors: URL
        let identity: ProcessReference?
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let device = "11111111-1111-4111-8111-111111111111"
    var paths: LeasePaths { LeasePaths(root: root.appendingPathComponent("cache")) }
    var inventory: URL { root.appendingPathComponent("inventory.json") }
    var failure: URL { root.appendingPathComponent("fail-shutdown") }
    var executable: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/simlease") }
    private var children = [Launch]()

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try setState("Shutdown")
        let script = """
        #!/bin/sh
        if [ "$2" = list ]; then /bin/cat "$NATIVE_INVENTORY"; exit 0; fi
        if [ "$2" = launch ]; then /usr/bin/printf '%s\\n' "$@" > "$NATIVE_ROOT/launch-arguments"; fi
        if [ "$2" = boot ]; then
          /usr/bin/grep -q Booted "$NATIVE_INVENTORY" && exit 149
          /usr/bin/touch "$NATIVE_ROOT/native-started"
          while [ -f "$NATIVE_ROOT/block-native" ]; do /bin/sleep 0.05; done
        fi
        if [ "$2" = shutdown ]; then
          [ ! -e "$NATIVE_FAILURE" ] || exit 1
          /usr/bin/sed 's/Booted/Shutdown/g' "$NATIVE_INVENTORY" > "$NATIVE_INVENTORY.tmp"
          /bin/mv "$NATIVE_INVENTORY.tmp" "$NATIVE_INVENTORY"
        fi
        """
        let shims = root.appendingPathComponent("shims")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        for name in ["xcrun", "xcodebuild"] {
            try FileManager.default.createSymbolicLink(at: shims.appendingPathComponent(name), withDestinationURL: executable)
        }
        let runner = root.appendingPathComponent("xcodebuild")
        try Data("#!/bin/sh\n/usr/bin/touch \"$NATIVE_ROOT/runner-invoked\"\n".utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let tool = root.appendingPathComponent("xcrun")
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }

    deinit {
        for child in children where child.process.isRunning {
            child.process.terminate()
            let deadline = Date(timeIntervalSinceNow: 2)
            while child.process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.process.isRunning, child.identity?.state == .matching { _ = kill(child.process.processIdentifier, SIGKILL) }
            child.process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }

    func setState(_ state: String) throws {
        try JSONSerialization.data(withJSONObject: ["devices": ["test": [["udid": device, "name": "Test device", "state": state, "deviceTypeIdentifier": "test.phone", "dataPath": root.appendingPathComponent(device).path, "isAvailable": true]]]]).write(to: inventory)
    }

    func launch(_ arguments: [String], shim: Bool = false, tool: String = "xcrun") throws -> Launch {
        let output = root.appendingPathComponent(UUID().uuidString)
        let errors = root.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = shim ? root.appendingPathComponent("shims").appendingPathComponent(tool) : executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SIMLEASE_CACHE_ROOT": paths.root.path, "SIMLEASE_XCRUN_PATH": root.appendingPathComponent("xcrun").path,
            "NATIVE_INVENTORY": inventory.path, "NATIVE_FAILURE": failure.path,
            "NATIVE_ROOT": root.path, "PATH": root.appendingPathComponent("shims").path + ":" + root.path + ":/usr/bin:/bin",
        ]) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let result = Launch(process: process, output: output, errors: errors, identity: ProcessReference.capture(pid: process.processIdentifier))
        children.append(result)
        return result
    }

    func begin(clientPID: Int32? = nil) throws -> (Launch, [String: Any], SimulatorTaskRecord) {
        let binding = clientPID.map { ["--client-pid", String($0)] } ?? []
        let keeper = try launch(["session", "begin", "--device", device, "--title", "UI", "--project", "App"] + binding)
        try wait {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: keeper.output))) != nil || !keeper.process.isRunning
        }
        let data = try Data(contentsOf: keeper.output)
        let errors = (try? String(contentsOf: keeper.errors, encoding: .utf8)) ?? ""
        let ready = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any], errors)
        return (keeper, ready, try XCTUnwrap(SimulatorTaskStore(paths: paths).read()))
    }

    func callShim(_ arguments: [String], tool: String = "xcrun") throws -> Int32 { try exit(launch(arguments, shim: true, tool: tool)) }

    func call(_ arguments: [String]) throws -> Int32 { try exit(launch(arguments)) }

    func exit(_ launch: Launch) throws -> Int32 {
        try wait { !launch.process.isRunning }
        launch.process.waitUntilExit()
        return launch.process.terminationReason == .exit ? launch.process.terminationStatus : 128 + launch.process.terminationStatus
    }

    func wait(_ condition: () throws -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: 8)
        while try !condition() {
            guard Date() < deadline else { throw NSError(domain: "native session timeout", code: 1) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
