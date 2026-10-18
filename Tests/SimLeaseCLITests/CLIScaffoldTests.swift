import Foundation
import XCTest
import SimLeaseCore
import Darwin
@testable import SimLeaseCLI

final class CLIScaffoldTests: XCTestCase {
    func testCleanupUsesInternalXcrunWithShimFirstPath() throws {
        let fixture = try CLIFixture()
        let marker = fixture.root.appendingPathComponent("recursive-shim")
        let tools = try fixture.makeToolDirectory(name: "xcrun", script: "/usr/bin/touch \"$SHIM_MARKER\"; exit 1")
        let environment = [
            "PATH": "\(tools.path):/usr/bin:/bin", "SHIM_MARKER": marker.path,
            "SIMLEASE_CLEANUP_HOME": fixture.root.appendingPathComponent("home").path,
            "SIMLEASE_CLEANUP_TMP": fixture.root.appendingPathComponent("tmp").path,
        ]
        XCTAssertEqual(SimLeaseCLI.run(
            arguments: ["simlease", "clean", "plan", "--json"], environment: environment, configuration: fixture.configuration
        ), 0, fixture.errors.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAgentDeviceDaemonToolsDoNotReacquireClientLane() throws {
        let fixture = try CLIFixture()
        let pathFile = fixture.root.appendingPathComponent("daemon-path")
        let tools = try fixture.makeToolDirectory(name: "agent-device", script: "printf '%s' \"$PATH\" > \"$DAEMON_PATH\"")
        let xcrun = tools.appendingPathComponent("xcrun")
        try Data("#!/bin/sh\nexit 17\n".utf8).write(to: xcrun)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/simlease")
        for name in ["simlease", "agent-device", "xcrun"] {
            try FileManager.default.createSymbolicLink(at: fixture.shimDirectory.appendingPathComponent(name), withDestinationURL: executable)
        }
        let alias = fixture.root.appendingPathComponent("shim-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.shimDirectory)
        let environment = [
            "PATH": "\(fixture.shimDirectory.path):\(alias.path):\(tools.path):/usr/bin:/bin",
            "DAEMON_PATH": pathFile.path, "SIMLEASE_CACHE_ROOT": fixture.paths.root.path,
        ]
        let invocations = [
            [fixture.shimDirectory.appendingPathComponent("agent-device").path, "daemon", "start"],
            ["simlease", "run", "--", tools.appendingPathComponent("agent-device").path, "snapshot"],
            ["simlease", "run", "--", fixture.shimDirectory.appendingPathComponent("agent-device").path, "snapshot"],
        ]
        for invocation in invocations {
            XCTAssertEqual(SimLeaseCLI.run(arguments: invocation, environment: environment, configuration: fixture.configuration), 0)
            let daemonPath = try String(contentsOf: pathFile, encoding: .utf8)
            XCTAssertEqual(daemonPath, "\(tools.path):/usr/bin:/bin")
            let coordinator = LeaseCoordinator(paths: fixture.paths, store: try MetadataStore(paths: fixture.paths))
            let identity = LeaseIdentity(pid: getpid(), cwd: fixture.root.path, project: "client", command: [], source: .manualXcode, threadID: nil, threadTitle: nil)
            let handle = try XCTUnwrap(coordinator.tryAcquire(identity: identity))
            defer { handle.release() }
            let daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            daemon.arguments = ["xcrun", "simctl", "boot"]
            daemon.environment = ["PATH": daemonPath, "SIMLEASE_CACHE_ROOT": fixture.paths.root.path]
            daemon.standardOutput = Pipe()
            daemon.standardError = Pipe()
            try daemon.run()
            defer { fixture.stop(daemon) }
            let deadline = Date(timeIntervalSinceNow: 1)
            while daemon.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if daemon.isRunning { fixture.stop(daemon) }
            XCTAssertEqual(daemon.terminationStatus, 17)
        }
    }

    func testCrashRecoveryStopsVerifiedChildAndClearsJournal() throws {
        let fixture = try CLIFixture()
        let (process, record) = try fixture.startManagedTask()
        let child = try XCTUnwrap(record.child)
        defer {
            fixture.stop(process)
            try? TaskProcessRunner.stopGroup(child)
        }
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()

        let code = SimLeaseCLI.run(arguments: ["simlease", "recover"], environment: [:], configuration: fixture.configuration)

        XCTAssertEqual(code, 0)
        XCTAssertFalse(ProcessReference.isRunning(pid: child.pid))
        XCTAssertNil(try SimulatorTaskStore(paths: fixture.paths).read())
    }

    func testCopiedAndStaleTaskTokensCannotBypassActiveOwner() throws {
        let fixture = try CLIFixture(timeout: .milliseconds(80))
        let tools = try fixture.makeToolDirectory(name: "axe", script: "exit 0")
        let shim = try fixture.makeShim(name: "axe")
        let (first, firstRecord) = try fixture.startManagedTask()
        defer { fixture.stop(first) }
        let environment = [
            "PATH": "\(fixture.shimDirectory.path):\(tools.path)",
            "SIMLEASE_HELD": "1", "SIMLEASE_TOKEN": firstRecord.token,
        ]
        XCTAssertEqual(SimLeaseCLI.run(arguments: [shim.path, "tap"], environment: environment, configuration: fixture.configuration), 75)
        fixture.stop(first)
        let (second, secondRecord) = try fixture.startManagedTask()
        defer { fixture.stop(second) }
        XCTAssertNotEqual(firstRecord.token, secondRecord.token)
        XCTAssertEqual(SimLeaseCLI.run(arguments: [shim.path, "tap"], environment: environment, configuration: fixture.configuration), 75)
    }

    func testNestedTaskCannotAddDeviceOutsideOuterScope() throws {
        let fixture = try CLIFixture()
        let marker = fixture.root.appendingPathComponent("must-not-run")
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/simlease")
        let code = SimLeaseCLI.run(
            arguments: ["simlease", "run", "--", executable.path, "run", "--device", "11111111-1111-4111-8111-111111111111", "--", "/usr/bin/touch", marker.path],
            environment: ProcessInfo.processInfo.environment.merging(["SIMLEASE_CACHE_ROOT": fixture.paths.root.path]) { _, new in new },
            configuration: fixture.configuration
        )
        XCTAssertEqual(code, 74)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDoctorReportsMissingShimCoverage() throws {
        let fixture = try CLIFixture()
        XCTAssertEqual(SimLeaseCLI.run(
            arguments: ["simlease", "doctor", "--json"],
            environment: ["PATH": "/usr/bin:/bin"], configuration: fixture.configuration
        ), 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.output.value.utf8)) as? [String: Any])
        let commands = try XCTUnwrap(object["commands"] as? [[String: Any]])
        let xcrun = try XCTUnwrap(commands.first { $0["name"] as? String == "xcrun" })
        XCTAssertEqual(xcrun["shimmed"] as? Bool, false)
        XCTAssertEqual(xcrun["path"] as? String, "/usr/bin/xcrun")
    }

    func testRunAcceptsAbsoluteCommandAndPreservesFailureCode() throws {
        let fixture = try CLIFixture()
        let code = SimLeaseCLI.run(
            arguments: ["simlease", "run", "--", "/bin/sh", "-c", "exit 17"],
            environment: [:], configuration: fixture.configuration
        )
        XCTAssertEqual(code, 17)
        XCTAssertNil(try SimulatorTaskStore(paths: fixture.paths).read())
        XCTAssertEqual(try LeaseCoordinator(paths: fixture.paths, store: MetadataStore(paths: fixture.paths)).status().state, .free)
    }

    func testRunPreservesArgumentsWithoutShellEvaluation() throws {
        let fixture = try CLIFixture()
        let marker = fixture.root.appendingPathComponent("argument")
        let code = SimLeaseCLI.run(
            arguments: ["simlease", "run", "--", "/bin/sh", "-c", "printf '%s' \"$1\" > \"$2\"", "job", "value with spaces; literal", marker.path],
            environment: [:], configuration: fixture.configuration
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "value with spaces; literal")
    }

    func testNestedShimCanUseValidatedTaskScope() throws {
        let fixture = try CLIFixture()
        let tools = try fixture.makeToolDirectory(name: "axe", script: "exit 7")
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/simlease")
        let shim = fixture.shimDirectory.appendingPathComponent("axe")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: executable)

        let code = SimLeaseCLI.run(
            arguments: ["simlease", "run", "--", shim.path, "tap"],
            environment: ProcessInfo.processInfo.environment.merging([
                "PATH": "\(fixture.shimDirectory.path):\(tools.path):/usr/bin:/bin",
                "SIMLEASE_CACHE_ROOT": fixture.paths.root.path,
            ]) { _, new in new }, configuration: fixture.configuration
        )

        XCTAssertEqual(code, 7)
    }

    func testVersionPrintsPublicVersion() throws {
        let fixture = try CLIFixture()

        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: ["simlease", "--version"],
                environment: [:],
                configuration: fixture.configuration
            ),
            0
        )
        XCTAssertEqual(fixture.output.value, "simlease 0.1.2\n")
    }

    func testUpdatePassesCurrentVersionAndReturnsUpdaterStatus() throws {
        let runner = UpdateRunnerStub(exitCode: 17)
        let fixture = try CLIFixture(updateRunner: runner)

        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: ["simlease", "update"],
                environment: [:],
                configuration: fixture.configuration
            ),
            17
        )
        XCTAssertEqual(runner.arguments, ["--current-version", "0.1.2"])
    }

    func testDebugProductionConfigurationUsesCacheOverride() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let configuration = CLIConfiguration.production(
            environment: ["SIMLEASE_CACHE_ROOT": root.path]
        )

        XCTAssertEqual(configuration.paths.root, root.standardizedFileURL)
    }

    func testStatusJSONReportsFreeLease() throws {
        let fixture = try CLIFixture()

        let code = SimLeaseCLI.run(
            arguments: ["simlease", "status", "--json"],
            environment: [:],
            configuration: fixture.configuration
        )

        XCTAssertEqual(code, 0)
        let status = try JSONDecoder.simLease.decode(
            LeaseStatus.self,
            from: Data(fixture.output.value.utf8)
        )
        XCTAssertEqual(status.state, .free)
    }

    func testNameRequiresThreadIDAndRegistersTitle() throws {
        let fixture = try CLIFixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: ["simlease", "name", "[SimLease] CLI"],
                environment: [:],
                configuration: fixture.configuration
            ),
            64
        )

        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: ["simlease", "name", "[SimLease] CLI"],
                environment: ["CODEX_THREAD_ID": "019faaef"],
                configuration: fixture.configuration
            ),
            0
        )
        XCTAssertEqual(
            try MetadataStore(paths: fixture.paths).threadName(id: "019faaef"),
            "[SimLease] CLI"
        )
    }

    func testProtectedShimPreservesExitCode() throws {
        let fixture = try CLIFixture()
        let tools = try fixture.makeToolDirectory(name: "axe", script: "exit 7")
        let shim = try fixture.makeShim(name: "axe")

        let code = SimLeaseCLI.run(
            arguments: [shim.path, "tap"],
            environment: ["PATH": "\(fixture.shimDirectory.path):\(tools.path)"],
            configuration: fixture.configuration
        )

        XCTAssertEqual(code, 7)
        XCTAssertEqual(try MetadataStore(paths: fixture.paths).readOwner(), nil)
    }

    func testUnvalidatedHeldMarkerCannotBypassAnotherOwner() throws {
        let fixture = try CLIFixture(timeout: .milliseconds(80))
        let tools = try fixture.makeToolDirectory(
            name: "axe",
            script: "test \"$SIMLEASE_HELD\" = 1"
        )
        let shim = try fixture.makeShim(name: "axe")
        let holder = try fixture.startExternalHolder()
        defer { fixture.stop(holder) }

        let code = SimLeaseCLI.run(
            arguments: [shim.path, "tap"],
            environment: [
                "PATH": "\(fixture.shimDirectory.path):\(tools.path)",
                "SIMLEASE_HELD": "1",
            ],
            configuration: fixture.configuration
        )

        XCTAssertEqual(code, 75)
    }

    func testBusyProtectedShimTimesOutWith75() throws {
        let fixture = try CLIFixture(timeout: .milliseconds(80))
        let tools = try fixture.makeToolDirectory(name: "axe", script: "exit 0")
        let shim = try fixture.makeShim(name: "axe")
        let holder = try fixture.startExternalHolder()
        defer { fixture.stop(holder) }

        let code = SimLeaseCLI.run(
            arguments: [shim.path, "tap"],
            environment: ["PATH": "\(fixture.shimDirectory.path):\(tools.path)"],
            configuration: fixture.configuration
        )

        XCTAssertEqual(code, 75)
        XCTAssertEqual(try MetadataStore(paths: fixture.paths).readWaiters(), [])
    }

    func testParentSignalForwardsToChildAndReleasesLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let shims = root.appendingPathComponent("shims", isDirectory: true)
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)

        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/simlease")
        let shim = shims.appendingPathComponent("axe")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: executable)
        let tool = tools.appendingPathComponent("axe")
        let ready = root.appendingPathComponent("child-ready")
        try Data("#!/bin/sh\nprintf ready > \"$SIMLEASE_TEST_CHILD_READY\"\nexec /bin/sleep 5\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let process = Process()
        process.executableURL = shim
        process.arguments = ["tap"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(shims.path):\(tools.path)",
            "SIMLEASE_CACHE_ROOT": cache.path,
            "SIMLEASE_TEST_CHILD_READY": ready.path,
        ]) { _, new in new }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let store = try MetadataStore(paths: LeasePaths(root: cache))
        let coordinator = LeaseCoordinator(
            paths: LeasePaths(root: cache),
            store: store,
            timing: LeaseTiming(
                timeout: .seconds(1),
                reportInterval: .seconds(1),
                pollInterval: .milliseconds(10)
            )
        )
        let acquisitionDeadline = Date(timeIntervalSinceNow: 2)
        while Date() < acquisitionDeadline,
              !FileManager.default.fileExists(atPath: ready.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(try coordinator.status().state, .leased)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

        process.terminate()
        let exitDeadline = Date(timeIntervalSinceNow: 2)
        while process.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationStatus, 143)
        XCTAssertEqual(try coordinator.status().state, .free)
    }
}

private final class CLIFixture {
    let root: URL
    let paths: LeasePaths
    let shimDirectory: URL
    let output = LockedText()
    let errors = LockedText()
    let configuration: CLIConfiguration

    init(
        timeout: Duration = .milliseconds(150),
        updateRunner: (any UpdateRunning)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = LeasePaths(root: root.appendingPathComponent("cache", isDirectory: true))
        shimDirectory = root.appendingPathComponent("shims", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shimDirectory,
            withIntermediateDirectories: true
        )
        let output = output
        let errors = errors
        configuration = CLIConfiguration(
            paths: paths,
            timing: LeaseTiming(
                timeout: timeout,
                reportInterval: .milliseconds(30),
                pollInterval: .milliseconds(10)
            ),
            standardOutput: { text in output.append(text) },
            standardError: { text in errors.append(text) },
            updateRunner: updateRunner
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeShim(name: String) throws -> URL {
        let url = shimDirectory.appendingPathComponent(name)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func makeToolDirectory(name: String, script: String) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return directory
    }

    func startExternalHolder() throws -> Process {
        _ = try MetadataStore(paths: paths)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [paths.lock.path, "/bin/sleep", "5"]
        try process.run()

        let deadline = Date(timeIntervalSinceNow: 1)
        while Date() < deadline {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            probe.arguments = ["-t", "0", paths.lock.path, "/usr/bin/true"]
            probe.standardError = Pipe()
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus != 0 { return process }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("holder did not acquire lock")
        return process
    }

    func startManagedTask() throws -> (Process, SimulatorTaskRecord) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/simlease")
        process.arguments = ["run", "--", "/bin/sleep", "30"]
        process.environment = ProcessInfo.processInfo.environment.merging(["SIMLEASE_CACHE_ROOT": paths.root.path]) { _, new in new }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if let record = try SimulatorTaskStore(paths: paths).read(), record.phase == .running, record.child != nil {
                return (process, record)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        stop(process)
        throw NSError(domain: "managed task did not start", code: 1)
    }

    func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

private final class UpdateRunnerStub: UpdateRunning, @unchecked Sendable {
    private let exitCode: Int32
    private(set) var arguments: [String] = []

    init(exitCode: Int32) {
        self.exitCode = exitCode
    }

    func run(arguments: [String]) throws -> Int32 {
        self.arguments = arguments
        return exitCode
    }
}

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    var value: String {
        lock.withLock { text }
    }

    func append(_ value: String) {
        lock.withLock { text += value }
    }
}
