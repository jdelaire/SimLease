import XCTest
@testable import SimLeaseCore

final class LaneHistoryStoreTests: XCTestCase {
    func testTypicalDurationNeedsThreeSamplesAndUsesMedian() throws {
        let paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = LaneHistoryStore(paths: paths)
        let start = Date(timeIntervalSince1970: 1_000)
        for seconds in [600.0, 60, 120] { try store.record(project: "ExplorerDex", startedAt: start, endedAt: start.addingTimeInterval(seconds)) }
        for seconds in [30.0, 40] { try store.record(project: "Set", startedAt: start, endedAt: start.addingTimeInterval(seconds)) }
        XCTAssertEqual(store.typicalDurations(projects: ["ExplorerDex", "Set", "Other"]), ["ExplorerDex": 120])
    }

    func testNativeActivityBelongsToItsSession() throws {
        let paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = LaneHistoryStore(paths: paths)
        let at = Date(timeIntervalSince1970: 5_000)
        try store.recordNativeActivity(sessionID: "session-a", at: at)
        XCTAssertEqual(store.lastNativeActivity(sessionID: "session-a"), at)
        XCTAssertNil(store.lastNativeActivity(sessionID: "session-b"))
    }
}
