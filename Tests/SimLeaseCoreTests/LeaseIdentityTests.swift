import Foundation
import XCTest
@testable import SimLeaseCore

final class LeaseIdentityTests: XCTestCase {
    func testRegisteredTitleWinsForCodexThread() throws {
        let store = try MetadataStore(paths: temporaryPaths())
        try store.registerThreadName(id: "019faaef", title: "[SimLease] Build CLI")

        let identity = try LeaseIdentity.resolve(
            environment: ["CODEX_THREAD_ID": "019faaef"],
            cwd: "/Users/me/Projects/SimLease",
            command: ["xcrun", "simctl", "list"],
            store: store,
            pid: 41
        )

        XCTAssertEqual(identity.pid, 41)
        XCTAssertEqual(identity.source, .codex)
        XCTAssertEqual(identity.project, "SimLease")
        XCTAssertEqual(identity.threadTitle, "[SimLease] Build CLI")
    }

    func testMissingTitleKeepsFullIDInMetadata() throws {
        let identity = try LeaseIdentity.resolve(
            environment: ["CODEX_THREAD_ID": "019faaef-c552-7933"],
            cwd: "/Users/me/Projects/SimLease",
            command: ["axe", "tap"],
            store: try MetadataStore(paths: temporaryPaths()),
            pid: 52
        )

        XCTAssertEqual(identity.threadID, "019faaef-c552-7933")
        XCTAssertNil(identity.threadTitle)
    }

    func testTerminalIdentityUsesProjectDirectory() throws {
        let identity = try LeaseIdentity.resolve(
            environment: [:],
            cwd: "/Users/me/Projects/Set/",
            command: ["xcodebuild", "test"],
            store: try MetadataStore(paths: temporaryPaths()),
            pid: 63
        )

        XCTAssertEqual(identity.source, .terminal)
        XCTAssertEqual(identity.project, "Set")
        XCTAssertNil(identity.threadID)
    }

    private func temporaryPaths() -> LeasePaths {
        LeasePaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }
}
