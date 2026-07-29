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
}
