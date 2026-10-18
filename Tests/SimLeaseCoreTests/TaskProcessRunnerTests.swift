import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class TaskProcessRunnerTests: XCTestCase {
    func testProcessEnumerationFailureCannotReportAnEmptyGroup() throws {
        XCTAssertThrowsError(try TaskProcessRunner.runningMembers(group: getpid()) { _, _ in
            errno = EACCES
            return 0
        })
        XCTAssertEqual(try TaskProcessRunner.runningMembers(group: getpid()) { _, _ in
            errno = ESRCH
            return 0
        }, [])
    }

    func testCancellationWhileLeaderExitsKeepsOwnershipProof() throws {
        for _ in 0..<20 {
            let signals = TaskSignals()
            let code = try TaskProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 7"], environment: [:], signals: signals,
                onStart: { _ in signals.cancel() }
            )
            XCTAssertTrue([7, 143].contains(code))
        }
    }

    func testExitJournalFailurePreservesKnownJobFailure() throws {
        XCTAssertThrowsError(try TaskProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"], environment: [:], signals: TaskSignals(),
            onStart: { _ in }, onExit: { _, _ in throw NSError(domain: "journal", code: 1) }
        )) {
            XCTAssertEqual(($0 as? TaskProcessCleanupError)?.exitCode, 7)
        }
    }

    func testJobRetainsNormalSignalBehavior() throws {
        let code = try TaskProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$"], environment: [:],
            signals: TaskSignals(), onStart: { _ in }
        )
        XCTAssertEqual(code, 143)
    }

    func testChildCannotExecuteBeforeIdentityIsJournaled() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }

        XCTAssertThrowsError(try TaskProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path], environment: [:], signals: TaskSignals(),
            onStart: { _ in throw NSError(domain: "journal", code: 1) }
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOwnedBackgroundChildrenAreStoppedBeforeReturning() throws {
        for _ in 0..<20 {
            try verifyBackgroundChildCleanup()
        }
    }

    private func verifyBackgroundChildCleanup() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = try TaskProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 30 & echo $! > \"$1\"; exit 7", "job", pidFile.path],
            environment: [:], signals: TaskSignals(), onStart: { _ in }
        )

        XCTAssertEqual(result, 7)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(ProcessReference.isRunning(pid: pid))
    }
}
