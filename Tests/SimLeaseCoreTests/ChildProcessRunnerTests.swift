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

    func testPassesLeaseMarkerToChild() throws {
        let result = try ChildProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test \"$SIMLEASE_HELD\" = 1"],
            environment: ["SIMLEASE_HELD": "1"]
        )

        XCTAssertEqual(result.exitCode, 0)
    }
}
