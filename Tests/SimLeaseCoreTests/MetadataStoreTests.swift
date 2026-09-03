import Foundation
import XCTest
@testable import SimLeaseCore

final class MetadataStoreTests: XCTestCase {
    func testOwnerRoundTrip() throws {
        let paths = temporaryPaths()
        let store = try MetadataStore(paths: paths)
        let owner = makeOwner()

        try store.writeOwner(owner)

        XCTAssertEqual(try store.readOwner(), owner)
    }

    func testWaitersSortByStartAndRemovingOnePreservesOthers() throws {
        let store = try MetadataStore(paths: temporaryPaths())
        let later = makeWaiter(id: "52-120", waitingSince: 120)
        let earlier = makeWaiter(id: "41-100", waitingSince: 100)

        try store.writeWaiter(later)
        try store.writeWaiter(earlier)
        XCTAssertEqual(try store.readWaiters().map(\.id), ["41-100", "52-120"])

        try store.removeWaiter(id: earlier.id)
        XCTAssertEqual(try store.readWaiters(), [later])
    }

    func testMissingFilesReadAsNil() throws {
        let store = try MetadataStore(paths: temporaryPaths())

        XCTAssertNil(try store.readOwner())
        XCTAssertEqual(try store.readWaiters(), [])
    }

    func testInvalidOwnerJSONReturnsCorruptionError() throws {
        let paths = temporaryPaths()
        let store = try MetadataStore(paths: paths)
        try Data("not-json".utf8).write(to: paths.owner)

        XCTAssertThrowsError(try store.readOwner()) { error in
            XCTAssertEqual(error as? MetadataStoreError, .corruptFile(paths.owner))
        }
    }

    func testCorruptWaiterFileIsQuarantinedAndSkipped() throws {
        let paths = temporaryPaths()
        let store = try MetadataStore(paths: paths)
        let valid = makeWaiter(id: "52-120", waitingSince: 120)
        try store.writeWaiter(valid)
        let corruptURL = paths.waiters.appendingPathComponent("41-100.json")
        try Data("not-json".utf8).write(to: corruptURL)

        XCTAssertEqual(try store.readWaiters(), [valid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        let quarantine = paths.waiters.appendingPathComponent(
            ".quarantine",
            isDirectory: true
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantined.count, 1)
    }

    func testThreadNameRejectsEmptyTitle() throws {
        let store = try MetadataStore(paths: temporaryPaths())

        XCTAssertThrowsError(try store.registerThreadName(id: "019faaef", title: "  ")) {
            XCTAssertEqual($0 as? MetadataStoreError, .invalidThreadTitle)
        }
    }

    private func temporaryPaths() -> LeasePaths {
        LeasePaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }

    private func makeOwner() -> LeaseOwner {
        LeaseOwner(
            pid: 41,
            acquiredAt: Date(timeIntervalSince1970: 100),
            cwd: "/Projects/SimLease",
            project: "SimLease",
            command: ["xcrun", "simctl", "list"],
            source: .codex,
            threadID: "019faaef",
            threadTitle: "[SimLease] Build CLI"
        )
    }

    private func makeWaiter(id: String, waitingSince: TimeInterval) -> LeaseWaiter {
        LeaseWaiter(
            id: id,
            pid: 52,
            waitingSince: Date(timeIntervalSince1970: waitingSince),
            cwd: "/Projects/Set",
            project: "Set",
            command: ["axe", "tap"],
            source: .terminal,
            threadID: nil,
            threadTitle: nil
        )
    }
}
