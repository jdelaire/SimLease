import Foundation
import XCTest
@testable import SimLeaseCore

final class LanePlanStoreTests: XCTestCase {
    func testSaveConsumeOnceAndPrivatePermissions() throws {
        let fixture = try Fixture()
        let plan = makePlan(id: "ABC123")
        try fixture.store.save(plan)

        XCTAssertEqual(permissions(fixture.paths.lanePlans), 0o700)
        XCTAssertEqual(permissions(fixture.planURL(plan.id)), 0o600)
        XCTAssertEqual(
            try fixture.store.consume(id: plan.id, now: plan.createdAt.addingTimeInterval(1)),
            plan
        )
        XCTAssertThrowsError(try fixture.store.consume(id: plan.id, now: plan.createdAt)) {
            XCTAssertEqual($0 as? LanePlanStoreError, .missing)
        }
    }

    func testRejectsInvalidIDsAndDuplicates() throws {
        let fixture = try Fixture()
        for id in ["abc123", "ABC-12", "ABC12", "ABC1234"] {
            XCTAssertThrowsError(try fixture.store.save(makePlan(id: id))) {
                XCTAssertEqual($0 as? LanePlanStoreError, .invalidID)
            }
        }
        try fixture.store.save(makePlan(id: "ABC123"))
        XCTAssertThrowsError(try fixture.store.save(makePlan(id: "ABC123"))) {
            XCTAssertEqual($0 as? LanePlanStoreError, .alreadyExists)
        }
    }

    func testExpiredOrChangedPlanIsRejectedAndConsumed() throws {
        let fixture = try Fixture()
        let expired = makePlan(id: "OLD123")
        try fixture.store.save(expired)
        XCTAssertThrowsError(
            try fixture.store.consume(id: expired.id, now: expired.expiresAt)
        ) {
            XCTAssertEqual($0 as? LanePlanStoreError, .expired)
        }

        let changed = makePlan(id: "BAD123")
        try fixture.store.save(changed)
        let url = fixture.planURL(changed.id)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var plan = try XCTUnwrap(object["plan"] as? [String: Any])
        plan["laneID"] = "lane-9"
        object["plan"] = plan
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(
            try fixture.store.consume(id: changed.id, now: changed.createdAt)
        ) {
            XCTAssertEqual($0 as? LanePlanStoreError, .invalidIntegrity)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPruneRemovesOnlyOldLanePlanFiles() throws {
        let fixture = try Fixture()
        let now = Date(timeIntervalSince1970: 3_000_000)
        try fixture.store.save(makePlan(id: "OLD123"))
        try fixture.store.save(makePlan(id: "NEW123"))
        let unrelated = fixture.paths.lanePlans.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-86_401)],
            ofItemAtPath: fixture.planURL("OLD123").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-86_399)],
            ofItemAtPath: fixture.planURL("NEW123").path
        )

        try fixture.store.prune(now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.planURL("OLD123").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.planURL("NEW123").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func makePlan(id: String) -> LaneLifecyclePlan {
        LaneLifecyclePlan(
            id: id,
            kind: .recovery,
            createdAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_600),
            laneID: "lane-1",
            reservationGeneration: 1,
            lastActivityAt: Date(timeIntervalSince1970: 500),
            fingerprint: ManagedSimulatorFingerprint(
                udid: "UDID-1",
                deviceTypeIdentifier: "TYPE-1",
                runtimeIdentifier: "RUNTIME-1",
                standardizedDataPath: "/tmp/Devices/UDID-1",
                state: "Shutdown"
            )
        )
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class Fixture {
    let paths: LeasePaths
    let store: LanePlanStore

    init() throws {
        paths = LeasePaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        store = try LanePlanStore(paths: paths)
    }

    deinit { try? FileManager.default.removeItem(at: paths.root) }

    func planURL(_ id: String) -> URL {
        paths.lanePlans.appendingPathComponent("\(id).json")
    }
}
