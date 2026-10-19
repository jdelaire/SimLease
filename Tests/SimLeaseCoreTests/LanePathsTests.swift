import XCTest
@testable import SimLeaseCore

final class LanePathsTests: XCTestCase {
    func testOnlyLaneStateMovesIntoLaneDirectories() {
        let base = LeasePaths(root: URL(fileURLWithPath: "/tmp/simlease-base"))
        let second = base.lane(1)
        XCTAssertEqual(base.lock.path, "/tmp/simlease-base/lease.lock")
        XCTAssertEqual(second.lock.path, "/tmp/simlease-base/lane-1/lease.lock")
        XCTAssertEqual(second.task.path, "/tmp/simlease-base/lane-1/task.json")
        XCTAssertEqual(second.owner.path, "/tmp/simlease-base/lane-1/owner.json")
        for shared in [\LeasePaths.waiters, \.deviceRecovery, \.deviceShutdown, \.threadNames, \.cleanupPlans, \.config, \.gate] {
            XCTAssertEqual(second[keyPath: shared], base[keyPath: shared])
        }
        XCTAssertEqual(second.deviceLock("abc"), base.deviceLock("ABC"))
        XCTAssertNotEqual(base.workspaceLock("/a"), base.workspaceLock("/b"))
    }

    func testConcurrentSharedStoreUpdatesAreNotLost() throws {
        let paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = WarmDeviceStore(paths: paths)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<20 { try? store.add(["device-\(worker)-\(index)"], since: Date()) }
        }
        XCTAssertEqual(try store.read().count, 160)
    }
}
