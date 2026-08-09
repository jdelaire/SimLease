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
        XCTAssertEqual(fixture.output.value, "simlease 0.2.0\n")
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
        XCTAssertEqual(runner.arguments, ["--current-version", "0.2.0"])
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

    func testLaneShimRejectsWrongTargetBeforeStartingChild() throws {
        let fixture = try CLIFixture()
        let marker = fixture.root.appendingPathComponent("child-started")
        let tools = try fixture.makeToolDirectory(
            name: "axe",
            script: "/usr/bin/touch \"\(marker.path)\""
        )
        let shim = try fixture.makeShim(name: "axe")
        let descriptor = try fixture.createLaneDescriptor(slot: 1, udid: "UDID-1")

        let code = SimLeaseCLI.run(
            arguments: [shim.path, "tap", "--udid", "OTHER"],
            environment: [
                "PATH": "\(fixture.shimDirectory.path):\(tools.path):/usr/bin:/bin",
                "SIMLEASE_LANE_FILE": descriptor.path,
            ],
            configuration: fixture.configuration
        )

        XCTAssertEqual(code, 76)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDifferentLaneCommandsOverlap() throws {
        let fixture = try CLIFixture(timeout: .seconds(2))
        let lane1Marker = fixture.root.appendingPathComponent("UDID-1")
        let lane2Marker = fixture.root.appendingPathComponent("UDID-2")
        let tools = try fixture.makeToolDirectory(
            name: "axe",
            script: """
            /usr/bin/touch "\(fixture.root.path)/$3"
            count=0
            while [ ! -f "\(lane1Marker.path)" ] || [ ! -f "\(lane2Marker.path)" ]; do
              count=$((count + 1))
              [ "$count" -gt 100 ] && exit 9
              /bin/sleep 0.01
            done
            """
        )
        let shim = try fixture.makeShim(name: "axe")
        let lane1 = try fixture.createLaneDescriptor(slot: 1, udid: "UDID-1")
        let lane2 = try fixture.createLaneDescriptor(slot: 2, udid: "UDID-2")
        let codes = LockedCodes()
        let group = DispatchGroup()
        for (descriptor, udid) in [(lane1, "UDID-1"), (lane2, "UDID-2")] {
            group.enter()
            DispatchQueue.global().async {
                let code = SimLeaseCLI.run(
                    arguments: [shim.path, "tap", "--udid", udid],
                    environment: [
                        "PATH": "\(fixture.shimDirectory.path):\(tools.path):/usr/bin:/bin",
                        "SIMLEASE_LANE_FILE": descriptor.path,
                    ],
                    configuration: fixture.configuration
                )
                codes.append(code)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(codes.value.sorted(), [0, 0])
    }

    func testCommandsInSameLaneSerialize() throws {
        let fixture = try CLIFixture(timeout: .seconds(2))
        let critical = fixture.root.appendingPathComponent("critical")
        let overlap = fixture.root.appendingPathComponent("overlap")
        let tools = try fixture.makeToolDirectory(
            name: "axe",
            script: """
            if ! /bin/mkdir "\(critical.path)" 2>/dev/null; then
              /usr/bin/touch "\(overlap.path)"
              exit 9
            fi
            /bin/sleep 0.15
            /bin/rmdir "\(critical.path)"
            """
        )
        let shim = try fixture.makeShim(name: "axe")
        let descriptor = try fixture.createLaneDescriptor(slot: 1, udid: "UDID-1")
        let codes = LockedCodes()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                let code = SimLeaseCLI.run(
                    arguments: [shim.path, "tap", "--udid", "UDID-1"],
                    environment: [
                        "PATH": "\(fixture.shimDirectory.path):\(tools.path):/usr/bin:/bin",
                        "SIMLEASE_LANE_FILE": descriptor.path,
                    ],
                    configuration: fixture.configuration
                )
                codes.append(code)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(codes.value.sorted(), [0, 0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlap.path))
    }

    func testLegacyGlobalCommandWaitsForActiveLane() throws {
        let fixture = try CLIFixture(timeout: .seconds(2))
        let laneStarted = fixture.root.appendingPathComponent("lane-started")
        let allowLane = fixture.root.appendingPathComponent("allow-lane")
        let globalStarted = fixture.root.appendingPathComponent("global-started")
        let axeTools = try fixture.makeToolDirectory(
            name: "axe",
            script: """
            /usr/bin/touch "\(laneStarted.path)"
            while [ ! -f "\(allowLane.path)" ]; do /bin/sleep 0.01; done
            """
        )
        let xcrunTools = try fixture.makeToolDirectory(
            name: "xcrun",
            script: "/usr/bin/touch \"\(globalStarted.path)\""
        )
        let axeShim = try fixture.makeShim(name: "axe")
        let xcrunShim = try fixture.makeShim(name: "xcrun")
        let descriptor = try fixture.createLaneDescriptor(slot: 1, udid: "UDID-1")
        let path = "\(fixture.shimDirectory.path):\(axeTools.path):\(xcrunTools.path):/usr/bin:/bin"
        let codes = LockedCodes()
        let laneGroup = DispatchGroup()
        laneGroup.enter()
        DispatchQueue.global().async {
            codes.append(SimLeaseCLI.run(
                arguments: [axeShim.path, "tap", "--udid", "UDID-1"],
                environment: ["PATH": path, "SIMLEASE_LANE_FILE": descriptor.path],
                configuration: fixture.configuration
            ))
            laneGroup.leave()
        }
        XCTAssertTrue(waitForFile(laneStarted, timeout: 1))

        laneGroup.enter()
        DispatchQueue.global().async {
            codes.append(SimLeaseCLI.run(
                arguments: [xcrunShim.path, "simctl", "list"],
                environment: ["PATH": path],
                configuration: fixture.configuration
            ))
            laneGroup.leave()
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalStarted.path))
        try Data().write(to: allowLane)

        XCTAssertEqual(laneGroup.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(codes.value.sorted(), [0, 0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalStarted.path))
    }

    func testLegacyCommandCannotTargetReservedManagedUDID() throws {
        let fixture = try CLIFixture()
        let marker = fixture.root.appendingPathComponent("child-started")
        let tools = try fixture.makeToolDirectory(
            name: "xcrun",
            script: "/usr/bin/touch \"\(marker.path)\""
        )
        let shim = try fixture.makeShim(name: "xcrun")
        _ = try fixture.createLaneDescriptor(slot: 1, udid: "UDID-1")

        let code = SimLeaseCLI.run(
            arguments: [shim.path, "simctl", "boot", "UDID-1"],
            environment: [
                "PATH": "\(fixture.shimDirectory.path):\(tools.path):/usr/bin:/bin",
            ],
            configuration: fixture.configuration
        )

        XCTAssertEqual(code, 76)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
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

private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

private final class CLIFixture: @unchecked Sendable {
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

    func createLaneDescriptor(slot: Int, udid: String) throws -> URL {
        let store = try LaneStore(paths: paths)
        let now = Date()
        let descriptor = LaneDescriptor(
            laneID: "lane-\(slot)",
            slot: slot,
            token: "TOKEN-\(slot)",
            project: "Project-\(slot)",
            threadID: "thread-\(slot)",
            threadTitle: "Lane \(slot)",
            udid: udid,
            deviceTypeIdentifier: "TYPE-1",
            deviceTypeName: "iPhone 17 Pro",
            runtimeIdentifier: "RUNTIME-1",
            runtimeName: "iOS 27.0",
            derivedDataPath: paths.laneDerivedData
                .appendingPathComponent("Project-\(slot)/lane-\(slot)").path,
            acquiredAt: now,
            lastActivityAt: now,
            expiresAt: now.addingTimeInterval(7_200)
        )
        let descriptorURL = try store.writeDescriptor(descriptor)
        var state = try store.readState()
        state.reservations.append(LaneReservation(
            laneID: descriptor.laneID,
            slot: slot,
            token: descriptor.token,
            project: descriptor.project,
            threadID: descriptor.threadID,
            threadTitle: descriptor.threadTitle,
            udid: udid,
            descriptorPath: descriptorURL.path,
            generation: 1,
            acquiredAt: now,
            lastActivityAt: now,
            expiresAt: descriptor.expiresAt
        ))
        state.managedDevices.append(ManagedSimulatorRecord(
            udid: udid,
            name: "[SimLease] Project-\(slot) \(slot)",
            deviceTypeIdentifier: descriptor.deviceTypeIdentifier,
            deviceTypeName: descriptor.deviceTypeName,
            runtimeIdentifier: descriptor.runtimeIdentifier,
            runtimeName: descriptor.runtimeName,
            expectedDataPath: "/tmp/Devices/\(udid)",
            createdAt: now,
            lifecycle: .reserved
        ))
        try store.writeState(state)
        return descriptorURL
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

private final class LockedCodes: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [Int32] = []

    var value: [Int32] { lock.withLock { codes } }
    func append(_ value: Int32) { lock.withLock { codes.append(value) } }
}
