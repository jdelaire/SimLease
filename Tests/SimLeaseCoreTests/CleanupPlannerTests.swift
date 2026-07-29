import Foundation
import XCTest
@testable import SimLeaseCore

final class CleanupPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)
    private let devicesRoot = URL(fileURLWithPath: "/Users/test/Devices")

    func testThirtyDayBoundaryIsEligibleButOneSecondNewerIsProtected() throws {
        let boundary = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let review = planner.makeReview(
            inventory: inventory(devices: [
                device(id: "OLD", lastUsedAt: boundary, sizeBytes: 100),
                device(
                    id: "NEW",
                    lastUsedAt: boundary.addingTimeInterval(1),
                    sizeBytes: 200
                ),
            ]),
            now: now,
            id: "ABC123"
        )

        XCTAssertEqual(review.plan?.devices.map(\.identifier), ["OLD"])
        XCTAssertEqual(reason(for: "NEW", in: review), .notOldEnough)
        XCTAssertEqual(review.estimatedBytes, 100)
    }

    func testBootedMissingAgeAndInvalidPathAreProtected() {
        let old = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let review = planner.makeReview(
            inventory: inventory(devices: [
                device(id: "BOOTED", state: "Booted", lastUsedAt: old),
                device(id: "NO-AGE", lastUsedAt: nil),
                device(
                    id: "BAD-PATH",
                    lastUsedAt: old,
                    dataPath: "/Users/test/Devices/OTHER/data"
                ),
            ]),
            now: now,
            id: "ABC123"
        )

        XCTAssertEqual(reason(for: "BOOTED", in: review), .booted)
        XCTAssertEqual(reason(for: "NO-AGE", in: review), .missingLastUsedAt)
        XCTAssertEqual(reason(for: "BAD-PATH", in: review), .invalidDataPath)
    }

    func testActiveTestsProtectEveryOtherwiseEligibleTarget() {
        let old = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let review = planner.makeReview(
            inventory: inventory(
                devices: [device(id: "DEVICE", lastUsedAt: old)],
                runtimes: [runtime(id: "IMAGE", runtimeID: "runtime.old")],
                outdatedRuntimeIDs: ["IMAGE"],
                hasActiveXcodeTests: true
            ),
            now: now,
            id: "ABC123"
        )

        XCTAssertNil(review.plan)
        XCTAssertEqual(reason(for: "DEVICE", in: review), .activeTests)
        XCTAssertEqual(reason(for: "IMAGE", in: review), .activeTests)
    }

    func testRuntimeMustBeOutdatedAndUnusedByBootedDevice() {
        let review = planner.makeReview(
            inventory: inventory(
                devices: [
                    device(
                        id: "BOOTED",
                        runtimeID: "runtime.booted",
                        state: "Booted",
                        lastUsedAt: now
                    ),
                ],
                runtimes: [
                    runtime(id: "CURRENT", runtimeID: "runtime.current"),
                    runtime(id: "IN-USE", runtimeID: "runtime.booted"),
                    runtime(id: "OLD", runtimeID: "runtime.old"),
                ],
                outdatedRuntimeIDs: ["IN-USE", "OLD"]
            ),
            now: now,
            id: "ABC123"
        )

        XCTAssertEqual(review.plan?.runtimes.map(\.identifier), ["OLD"])
        XCTAssertEqual(reason(for: "CURRENT", in: review), .notOutdated)
        XCTAssertEqual(reason(for: "IN-USE", in: review), .bootedRuntime)
    }

    func testUnknownSizesDoNotBlockAndKnownSizesSum() {
        let old = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let review = planner.makeReview(
            inventory: inventory(
                devices: [
                    device(id: "KNOWN", lastUsedAt: old, sizeBytes: 400),
                    device(id: "UNKNOWN", lastUsedAt: old, sizeBytes: nil),
                ],
                runtimes: [
                    runtime(id: "IMAGE", runtimeID: "runtime.old", sizeBytes: 600),
                ],
                outdatedRuntimeIDs: ["IMAGE"]
            ),
            now: now,
            id: "ABC123"
        )

        XCTAssertEqual(review.plan?.devices.count, 2)
        XCTAssertEqual(review.plan?.runtimes.count, 1)
        XCTAssertEqual(review.estimatedBytes, 1_000)
        XCTAssertEqual(review.plan?.estimatedBytes, 1_000)
    }

    func testNoEligibleTargetsProducesNoPlan() {
        let review = planner.makeReview(
            inventory: inventory(
                runtimes: [runtime(id: "CURRENT", runtimeID: "runtime.current")]
            ),
            now: now,
            id: "ABC123"
        )

        XCTAssertNil(review.plan)
        XCTAssertEqual(review.estimatedBytes, 0)
    }

    private var planner: CleanupPlanner {
        CleanupPlanner(devicesRoot: devicesRoot)
    }

    private func device(
        id: String,
        runtimeID: String = "runtime.current",
        state: String = "Shutdown",
        lastUsedAt: Date?,
        dataPath: String? = nil,
        sizeBytes: Int64? = nil
    ) -> CleanupDeviceRecord {
        CleanupDeviceRecord(
            identifier: id,
            name: id,
            runtimeIdentifier: runtimeID,
            state: state,
            lastUsedAt: lastUsedAt,
            dataPath: dataPath ?? devicesRoot
                .appendingPathComponent(id)
                .appendingPathComponent("data").path,
            sizeBytes: sizeBytes
        )
    }

    private func runtime(
        id: String,
        runtimeID: String,
        sizeBytes: Int64? = nil
    ) -> CleanupRuntimeRecord {
        CleanupRuntimeRecord(
            identifier: id,
            runtimeIdentifier: runtimeID,
            name: runtimeID,
            build: "1",
            sizeBytes: sizeBytes
        )
    }

    private func inventory(
        devices: [CleanupDeviceRecord] = [],
        runtimes: [CleanupRuntimeRecord] = [],
        outdatedRuntimeIDs: Set<String> = [],
        hasActiveXcodeTests: Bool = false
    ) -> CleanupInventory {
        CleanupInventory(
            devices: devices,
            runtimes: runtimes,
            outdatedRuntimeIDs: outdatedRuntimeIDs,
            hasActiveXcodeTests: hasActiveXcodeTests,
            availableBytes: 5_000
        )
    }

    private func reason(
        for id: String,
        in review: CleanupReview
    ) -> CleanupProtectionReason? {
        review.protected.first { $0.target.identifier == id }?.reason
    }
}
