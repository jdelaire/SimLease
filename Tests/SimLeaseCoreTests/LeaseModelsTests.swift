import Foundation
import XCTest
@testable import SimLeaseCore

final class LeaseModelsTests: XCTestCase {
    func testStatusRoundTripPreservesOwnerAndWaiters() throws {
        let owner = LeaseOwner(
            pid: 41,
            acquiredAt: Date(timeIntervalSince1970: 100),
            cwd: "/Projects/AnimAtlas",
            project: "AnimAtlas",
            command: ["/usr/bin/xcodebuild", "test"],
            source: .codex,
            threadID: "019faaef-c552-7933-92dc-1cf0ff89fc06",
            threadTitle: "[AnimAtlas] Onboarding"
        )
        let waiter = LeaseWaiter(
            id: "52-120",
            pid: 52,
            waitingSince: Date(timeIntervalSince1970: 120),
            cwd: "/Projects/Set",
            project: "Set",
            command: ["/usr/bin/xcrun", "simctl", "list"],
            source: .terminal,
            threadID: nil,
            threadTitle: nil
        )
        let value = LeaseStatus(state: .leased, owner: owner, waiters: [waiter], error: nil)

        let data = try JSONEncoder.simLease.encode(value)
        XCTAssertEqual(try JSONDecoder.simLease.decode(LeaseStatus.self, from: data), value)
    }

    func testFractionalSecondDatesRoundTripExactly() throws {
        let owner = LeaseOwner(
            pid: 41,
            acquiredAt: Date(timeIntervalSince1970: 1_000.5),
            cwd: "/Projects/AnimAtlas",
            project: "AnimAtlas",
            command: ["xcodebuild", "test"],
            source: .codex,
            threadID: nil,
            threadTitle: nil
        )
        let value = LeaseStatus(state: .leased, owner: owner, waiters: [], error: nil)

        let data = try JSONEncoder.simLease.encode(value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(".5"))
        XCTAssertEqual(try JSONDecoder.simLease.decode(LeaseStatus.self, from: data), value)
    }

    func testWholeSecondDatesFromOlderPayloadsStillDecode() throws {
        let json = """
        {"state":"leased","owner":{"pid":41,"acquiredAt":"1970-01-01T00:01:40Z","cwd":"/P","project":"P","command":[],"source":"codex","threadID":null,"threadTitle":null},"waiters":[],"lanes":[],"error":null}
        """.data(using: .utf8)!

        let status = try JSONDecoder.simLease.decode(LeaseStatus.self, from: json)

        XCTAssertEqual(status.owner?.acquiredAt, Date(timeIntervalSince1970: 100))
    }

    func testPathsStayInsideConfiguredRoot() {
        let paths = LeasePaths(root: URL(fileURLWithPath: "/tmp/simlease-test"))
        XCTAssertEqual(paths.lock.path, "/tmp/simlease-test/lease.lock")
        XCTAssertEqual(paths.owner.path, "/tmp/simlease-test/owner.json")
        XCTAssertEqual(paths.waiters.path, "/tmp/simlease-test/waiters")
        XCTAssertEqual(paths.threadNames.path, "/tmp/simlease-test/thread-names.json")
    }
}
