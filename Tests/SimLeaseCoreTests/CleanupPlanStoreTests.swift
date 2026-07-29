import Foundation
import XCTest
@testable import SimLeaseCore

final class CleanupPlanStoreTests: XCTestCase {
    func testSaveAndConsumeIsOneTimeAndUsesPrivatePermissions() throws {
        let fixture = try Fixture()
        let plan = makePlan(id: "ABC123")

        try fixture.store.save(plan)

        XCTAssertEqual(permissions(fixture.paths.cleanupPlans), 0o700)
        XCTAssertEqual(permissions(fixture.planURL("ABC123")), 0o600)
        XCTAssertEqual(
            try fixture.store.consume(
                id: "ABC123",
                now: plan.createdAt.addingTimeInterval(1)
            ),
            plan
        )
        XCTAssertThrowsError(
            try fixture.store.consume(id: "ABC123", now: plan.createdAt)
        ) {
            XCTAssertEqual($0 as? CleanupPlanStoreError, .missing)
        }
    }

    func testRejectsInvalidIDsAndDuplicatePlan() throws {
        let fixture = try Fixture()
        for id in ["abc123", "ABC-12", "ABC12", "ABC1234"] {
            XCTAssertThrowsError(try fixture.store.save(makePlan(id: id))) {
                XCTAssertEqual($0 as? CleanupPlanStoreError, .invalidID)
            }
            XCTAssertThrowsError(
                try fixture.store.consume(id: id, now: Date())
            ) {
                XCTAssertEqual($0 as? CleanupPlanStoreError, .invalidID)
            }
        }

        try fixture.store.save(makePlan(id: "ABC123"))
        XCTAssertThrowsError(try fixture.store.save(makePlan(id: "ABC123"))) {
            XCTAssertEqual($0 as? CleanupPlanStoreError, .alreadyExists)
        }
    }

    func testExpiredPlanIsRejectedAndConsumed() throws {
        let fixture = try Fixture()
        let plan = makePlan(id: "ABC123")
        try fixture.store.save(plan)

        XCTAssertThrowsError(
            try fixture.store.consume(
                id: plan.id,
                now: plan.expiresAt.addingTimeInterval(1)
            )
        ) {
            XCTAssertEqual($0 as? CleanupPlanStoreError, .expired)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.planURL(plan.id).path
        ))
    }

    func testChangedPayloadIsRejectedAndConsumed() throws {
        let fixture = try Fixture()
        let plan = makePlan(id: "ABC123")
        try fixture.store.save(plan)
        let url = fixture.planURL(plan.id)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        var storedPlan = try XCTUnwrap(object["plan"] as? [String: Any])
        storedPlan["estimatedBytes"] = 999
        object["plan"] = storedPlan
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        XCTAssertThrowsError(
            try fixture.store.consume(id: plan.id, now: plan.createdAt)
        ) {
            XCTAssertEqual($0 as? CleanupPlanStoreError, .invalidIntegrity)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPruneRemovesOnlyPlanFilesOlderThanTwentyFourHours() throws {
        let fixture = try Fixture()
        let now = Date(timeIntervalSince1970: 3_000_000)
        try fixture.store.save(makePlan(id: "OLD123"))
        try fixture.store.save(makePlan(id: "NEW123"))
        let unrelated = fixture.paths.root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-24 * 60 * 60 - 1)],
            ofItemAtPath: fixture.planURL("OLD123").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-24 * 60 * 60 + 1)],
            ofItemAtPath: fixture.planURL("NEW123").path
        )

        try fixture.store.prune(now: now)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.planURL("OLD123").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.planURL("NEW123").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func makePlan(id: String) -> CleanupPlan {
        CleanupPlan(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_600),
            devices: [],
            runtimes: [],
            protected: [],
            estimatedBytes: 0,
            availableBytesBefore: 100
        )
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class Fixture {
    let paths: LeasePaths
    let store: CleanupPlanStore

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = LeasePaths(root: root)
        store = try CleanupPlanStore(paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    func planURL(_ id: String) -> URL {
        paths.cleanupPlans.appendingPathComponent("\(id).json")
    }
}
