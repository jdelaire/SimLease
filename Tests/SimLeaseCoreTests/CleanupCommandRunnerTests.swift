import Foundation
import XCTest
@testable import SimLeaseCore

final class CleanupCommandRunnerTests: XCTestCase {
    func testCapturesLargeOutputAndNonzeroStatusWithoutDeadlock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let script = directory.appendingPathComponent("large-output.zsh")
        try Data(
            """
            #!/bin/zsh
            /usr/bin/head -c 100001 /dev/zero | /usr/bin/tr '\\0' x
            print -u2 -- failure
            exit 7
            """.utf8
        ).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )

        let output = try ProcessCleanupCommandRunner().run(
            executable: script,
            arguments: ["one", "two"],
            environment: [:]
        )

        XCTAssertEqual(output.exitCode, 7)
        XCTAssertEqual(output.stderr, "failure\n")
        XCTAssertEqual(output.stdout.utf8.count, 100_001)
    }
}
