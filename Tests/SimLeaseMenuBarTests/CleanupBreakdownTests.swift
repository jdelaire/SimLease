import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuCore

final class CleanupBreakdownTests: XCTestCase {
    func testGroupsCategoriesAndTracksSelectedBytes() {
        func target(_ id: String, _ category: CleanupCategory, _ size: Int64) -> CleanupTarget {
            CleanupTarget(kind: .filesystem, identifier: id, name: id, detail: "", category: category, riskTier: .rebuildable, action: .deletePermanently, path: "/tmp/\(id)", runtimeIdentifier: "", lastUsedAt: Date(timeIntervalSince1970: 0), sizeBytes: size, fingerprint: nil, selectedByDefault: false)
        }
        let plan = CleanupPlan(
            id: "PLAN", createdAt: Date(), expiresAt: Date(),
            devices: [target("device", .simulatorDevice, 300)], runtimes: [target("runtime", .simulatorRuntime, 700)],
            storage: [target("dd", .derivedData, 400), target("tmp", .temporaryDerivedData, 100), target("archive", .archive, 50)],
            protected: [], deferred: [], estimatedBytes: 1550, availableBytesBefore: nil
        )
        let breakdown = CleanupBreakdown(plan: plan, selected: ["runtime", "tmp"])
        XCTAssertEqual(breakdown.segments.map(\.group), [.simulators, .buildCaches, .archives])
        XCTAssertEqual(breakdown.segments.map(\.bytes), [1000, 500, 50])
        XCTAssertEqual(breakdown.segments.map(\.selectedBytes), [700, 100, 0])
        XCTAssertEqual(breakdown.totalBytes, 1550)
        XCTAssertEqual(breakdown.selectedBytes, 800)
        XCTAssertEqual(breakdown.largestTargetBytes, 700)
        XCTAssertEqual(CleanupBreakdown.unusedDays(target("x", .archive, 1), now: Date(timeIntervalSince1970: 86_400 * 10)), 10)
    }
}
