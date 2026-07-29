import Foundation
import XCTest
@testable import SimLeaseCore

final class CleanupModelsTests: XCTestCase {
    func testPlanRoundTripPreservesExactTargets() throws {
        let target = CleanupTarget(
            kind: .device,
            identifier: "A581B51F-3BEC-4957-B796-8A058AD2EDBC",
            name: "iPhone 17 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            lastUsedAt: Date(timeIntervalSince1970: 100),
            sizeBytes: 4_096
        )
        let plan = CleanupPlan(
            id: "ABC123",
            createdAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 800),
            devices: [target],
            runtimes: [],
            protected: [],
            estimatedBytes: 4_096,
            availableBytesBefore: 50_000
        )

        let decoded = try JSONDecoder.simLease.decode(
            CleanupPlan.self,
            from: JSONEncoder.simLease.encode(plan)
        )

        XCTAssertEqual(decoded, plan)
    }

    func testSkippedResultIsPartial() {
        let target = CleanupTarget(
            kind: .device,
            identifier: "DEVICE-1",
            name: "iPhone 17 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            lastUsedAt: nil,
            sizeBytes: nil
        )

        let result = CleanupResult(
            planID: "ABC123",
            items: [
                CleanupItemResult(
                    target: target,
                    outcome: .skipped,
                    message: "Device became booted"
                ),
            ],
            estimatedBytes: 0,
            availableBytesBefore: 50_000,
            availableBytesAfter: 50_000
        )

        XCTAssertTrue(result.isPartial)
    }

    func testFilesystemTargetRoundTripPreservesTierAndFingerprint() throws {
        let modified = Date(timeIntervalSince1970: 100)
        let target = CleanupTarget(
            kind: .filesystem,
            identifier: "derived-data:/tmp/example",
            name: "Example",
            detail: "/tmp/example",
            category: .temporaryDerivedData,
            riskTier: .rebuildable,
            action: .deletePermanently,
            path: "/tmp/example",
            runtimeIdentifier: "",
            lastUsedAt: modified,
            sizeBytes: 42,
            fingerprint: .filesystem(
                path: "/tmp/example",
                sizeBytes: 42,
                modifiedAt: modified
            ),
            selectedByDefault: true
        )
        let plan = CleanupPlan(
            id: "ABC123",
            createdAt: modified,
            expiresAt: modified.addingTimeInterval(600),
            devices: [],
            runtimes: [],
            storage: [target],
            protected: [],
            deferred: [.simulatorDevice, .simulatorRuntime],
            estimatedBytes: 42,
            availableBytesBefore: nil
        )

        let decoded = try JSONDecoder.simLease.decode(
            CleanupPlan.self,
            from: JSONEncoder.simLease.encode(plan)
        )

        XCTAssertEqual(decoded, plan)
        XCTAssertEqual(decoded.targets, [target])
        XCTAssertEqual(decoded.defaultSelectedTargetIDs, [target.identifier])
    }

    func testMovedToTrashResultIsNotPartial() {
        let target = CleanupTarget(
            kind: .filesystem,
            identifier: "archive:/tmp/App.xcarchive",
            name: "App.xcarchive",
            detail: "/tmp/App.xcarchive",
            category: .archive,
            riskTier: .guarded,
            action: .moveToTrash,
            path: "/tmp/App.xcarchive",
            runtimeIdentifier: "",
            lastUsedAt: nil,
            sizeBytes: 1,
            fingerprint: nil,
            selectedByDefault: false
        )
        let result = CleanupResult(
            planID: "ABC123",
            items: [
                CleanupItemResult(
                    target: target,
                    outcome: .movedToTrash,
                    message: "Moved to Trash"
                ),
            ],
            estimatedBytes: 1,
            availableBytesBefore: nil,
            availableBytesAfter: nil
        )

        XCTAssertFalse(result.isPartial)
    }
}
