import Foundation
import XCTest
@testable import SimLeaseCore

final class LaneLockCoordinatorTests: XCTestCase {
    func testDifferentSlotRemainsAvailableWhileExternalProcessHoldsSlotOne() throws {
        let fixture = try LockFixture()
        let holder = try fixture.startHolder(slot: 1)
        defer { fixture.stop(holder) }

        let second = try fixture.coordinator.acquire(slot: 2)
        XCTAssertThrowsError(try fixture.coordinator.acquire(slot: 1)) {
            XCTAssertEqual($0 as? LaneLockError, .timedOut)
        }
        second.release()
    }

    func testAcquireAllReleasesEarlierSlotsAfterTimeout() throws {
        let fixture = try LockFixture()
        let holder = try fixture.startHolder(slot: 2)
        defer { fixture.stop(holder) }

        XCTAssertThrowsError(try fixture.coordinator.acquireAll(maxSlot: 2))

        let first = try fixture.coordinator.acquire(slot: 1)
        first.release()
    }
}

private final class LockFixture {
    let root: URL
    let paths: LeasePaths
    let coordinator: LaneLockCoordinator

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = LeasePaths(root: root)
        coordinator = LaneLockCoordinator(
            paths: paths,
            timing: LeaseTiming(
                timeout: .milliseconds(80),
                reportInterval: .milliseconds(30),
                pollInterval: .milliseconds(10)
            )
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func startHolder(slot: Int) throws -> Process {
        let lockURL = paths.laneCommandLock(slot: slot)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [lockURL.path, "/bin/sleep", "5"]
        try process.run()
        let deadline = Date(timeIntervalSinceNow: 1)
        while Date() < deadline {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            probe.arguments = ["-t", "0", lockURL.path, "/usr/bin/true"]
            probe.standardError = Pipe()
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus != 0 { return process }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("holder did not acquire lane lock")
        return process
    }

    func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
