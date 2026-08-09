import Foundation
import XCTest
@testable import SimLeaseCore

final class ChildProcessRunnerTests: XCTestCase {
    func testReturnsExactChildExitCode() throws {
        let result = try ChildProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 7)
    }

    func testMapsSignalDeathToShellStatus() throws {
        let result = try ChildProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$"],
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 143)
    }

    func testConcurrentRunsRestoreSignalDispositionForNextChild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstStarted = root.appendingPathComponent("first-started")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let outcomes = LockedChildOutcomes()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outcomes.record(Result {
                try ChildProcessRunner.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "/usr/bin/touch \"\(firstStarted.path)\"; /bin/sleep 0.15",
                    ],
                    environment: [:]
                )
            })
            group.leave()
        }

        let deadline = Date(timeIntervalSinceNow: 2)
        while !FileManager.default.fileExists(atPath: firstStarted.path),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstStarted.path))

        group.enter()
        DispatchQueue.global().async {
            outcomes.record(Result {
                try ChildProcessRunner.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "/bin/sleep 0.35"],
                    environment: [:]
                )
            })
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(outcomes.errors, [])
        XCTAssertEqual(outcomes.exitCodes.sorted(), [0, 0])

        let result = try ChildProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$"],
            environment: [:]
        )
        XCTAssertEqual(result.exitCode, 143)
    }

    func testConcurrentRunDoesNotChangeChildSignalDefaults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstStarted = root.appendingPathComponent("first-started")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let outcomes = LockedChildOutcomes()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outcomes.record(Result {
                try ChildProcessRunner.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "/usr/bin/touch \"\(firstStarted.path)\"; /bin/sleep 0.35",
                    ],
                    environment: [:]
                )
            })
            group.leave()
        }

        let deadline = Date(timeIntervalSinceNow: 2)
        while !FileManager.default.fileExists(atPath: firstStarted.path),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstStarted.path))

        let result = try ChildProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$"],
            environment: [:]
        )
        XCTAssertEqual(result.exitCode, 143)
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(outcomes.errors, [])
        XCTAssertEqual(outcomes.exitCodes, [0])
    }

    func testPassesLeaseMarkerToChild() throws {
        let result = try ChildProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test \"$SIMLEASE_HELD\" = 1"],
            environment: ["SIMLEASE_HELD": "1"]
        )

        XCTAssertEqual(result.exitCode, 0)
    }
}

private final class LockedChildOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storedExitCodes: [Int32] = []
    private var storedErrors: [String] = []

    var exitCodes: [Int32] { lock.withLock { storedExitCodes } }
    var errors: [String] { lock.withLock { storedErrors } }

    func record(_ result: Result<ChildResult, Error>) {
        lock.withLock {
            switch result {
            case let .success(childResult):
                storedExitCodes.append(childResult.exitCode)
            case let .failure(error):
                storedErrors.append(String(describing: error))
            }
        }
    }
}
