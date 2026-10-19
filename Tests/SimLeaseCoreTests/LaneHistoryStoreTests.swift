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

    func testHeadroomSamplesAreThrottledAndJobsKeepLaneAndWait() throws {
        let paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = LaneHistoryStore(paths: paths)
        let start = Date(timeIntervalSince1970: 10_000)
        for offset in [0.0, 20, 61, 90, 130] {
            try store.recordSample(HeadroomRecord(at: start.addingTimeInterval(offset), memoryFreePercent: 50, cpuIdlePercent: 40, load: 3, lanesBusy: 1, laneLimit: 2, gateOpen: true))
        }
        XCTAssertEqual(store.samples(since: start).map(\.at), [0.0, 61, 130].map(start.addingTimeInterval))
        try store.record(project: "Set", startedAt: start, endedAt: start.addingTimeInterval(300), lane: 1, waitSeconds: 45)
        XCTAssertEqual(store.jobs(since: start).first.map { [$0.lane, Int($0.waitSeconds ?? 0)] }, [1, 45])
        XCTAssertTrue(store.jobs(since: start.addingTimeInterval(400)).isEmpty)
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
