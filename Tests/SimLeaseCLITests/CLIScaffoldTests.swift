import Foundation
import XCTest
import SimLeaseCore
import Darwin
@testable import SimLeaseCLI

final class CLIScaffoldTests: XCTestCase {
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
        XCTAssertEqual(fixture.output.value, "simlease 0.1.0\n")
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
        XCTAssertEqual(runner.arguments, ["--current-version", "0.1.0"])
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

    func testHeldMarkerSkipsRecursiveLeaseAttempt() throws {
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

        XCTAssertEqual(code, 0)
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
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let process = Process()
        process.executableURL = shim
        process.arguments = ["tap"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(shims.path):\(tools.path)",
            "SIMLEASE_CACHE_ROOT": cache.path,
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
              try coordinator.status().state != .leased {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(try coordinator.status().state, .leased)

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
