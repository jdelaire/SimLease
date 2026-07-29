import Foundation
import XCTest
@testable import SimLeaseCore

final class CleanupFileOperatorTests: XCTestCase {
    func testDeleteAllowsChildButRejectsAllowedRootAndOutsidePath() throws {
        let fixture = try OperatorFixture()
        defer { fixture.remove() }
        let child = fixture.allowed.appending(path: "cache")
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: false
        )
        let outside = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        let operation = CleanupFileOperator(allowedRoots: [fixture.allowed])

        try operation.delete(child)

        XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
        XCTAssertThrowsError(try operation.delete(fixture.allowed))
        XCTAssertThrowsError(try operation.delete(outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testTrashUsesTrashHandlerAndNeverDeletesDirectly() throws {
        let fixture = try OperatorFixture()
        defer { fixture.remove() }
        let child = fixture.allowed.appending(path: "archive")
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: false
        )
        let recorder = TrashRecorder()
        let operation = CleanupFileOperator(
            allowedRoots: [fixture.allowed],
            trashHandler: { recorder.record($0) }
        )

        try operation.trash(child)

        XCTAssertEqual(recorder.urls, [child.resolvingSymlinksInPath()])
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    }
}

private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [URL]()

    var urls: [URL] {
        lock.withLock { stored }
    }

    func record(_ url: URL) {
        lock.withLock { stored.append(url) }
    }
}

private struct OperatorFixture {
    let root: URL
    let allowed: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        allowed = root.appending(path: "allowed")
        try FileManager.default.createDirectory(
            at: allowed,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
