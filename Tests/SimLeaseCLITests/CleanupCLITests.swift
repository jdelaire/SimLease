import Foundation
import XCTest
import SimLeaseCore
@testable import SimLeaseCLI

final class CleanupCLITests: XCTestCase {
    func testPlanAndApplyJSONDecodeAsSharedModels() throws {
        let review = makeReview()
        let result = makeResult()
        let stub = CleanupServiceStub(
            plan: .success(review),
            apply: .success(result)
        )
        let fixture = try CleanupCLIFixture(stub: stub)

        XCTAssertEqual(fixture.run(["simlease", "clean", "plan", "--json"]), 0)
        XCTAssertEqual(
            try JSONDecoder.simLease.decode(
                CleanupReview.self,
                from: Data(fixture.output.value.utf8)
            ),
            review
        )

        fixture.output.clear()
        XCTAssertEqual(
            fixture.run([
                "simlease", "clean", "apply", "ABC123",
                "--target", "DEVICE-1",
                "--json",
            ]),
            0
        )
        XCTAssertEqual(stub.selectedTargetIDs, ["DEVICE-1"])
        XCTAssertEqual(
            try JSONDecoder.simLease.decode(
                CleanupResult.self,
                from: Data(fixture.output.value.utf8)
            ),
            result
        )
    }

    func testHumanPlanPrintsGroupsEstimateIDAndExpiry() throws {
        let fixture = try CleanupCLIFixture(
            stub: CleanupServiceStub(
                plan: .success(makeReview()),
                apply: .success(makeResult())
            )
        )

        XCTAssertEqual(fixture.run(["simlease", "clean", "plan"]), 0)

        let output = fixture.output.value
        XCTAssertTrue(output.contains("Devices"))
        XCTAssertTrue(output.contains("Runtimes"))
        XCTAssertTrue(output.contains("Rebuildable Caches"))
        XCTAssertTrue(output.contains("Guarded Storage"))
        XCTAssertTrue(output.contains("Deferred"))
        XCTAssertTrue(output.contains("Protected"))
        XCTAssertTrue(output.contains("Estimated"))
        XCTAssertTrue(output.contains("ABC123"))
        XCTAssertTrue(output.contains("Expires"))
    }

    func testEmptyPlanPrintsNoEligibleMessage() throws {
        let fixture = try CleanupCLIFixture(
            stub: CleanupServiceStub(
                plan: .success(CleanupReview(
                    plan: nil,
                    protected: [],
                    estimatedBytes: 0
                )),
                apply: .success(makeResult())
            )
        )

        XCTAssertEqual(fixture.run(["simlease", "clean", "plan"]), 0)
        XCTAssertEqual(
            fixture.output.value,
            "No eligible Xcode storage cleanup is available\n"
        )
    }

    func testPartialApplyReturns76() throws {
        let target = makeTarget(kind: .device, id: "DEVICE-1")
        let partial = CleanupResult(
            planID: "ABC123",
            items: [
                CleanupItemResult(
                    target: target,
                    outcome: .skipped,
                    message: "Device became booted"
                ),
            ],
            estimatedBytes: 100,
            availableBytesBefore: 1_000,
            availableBytesAfter: 1_000
        )
        let fixture = try CleanupCLIFixture(
            stub: CleanupServiceStub(
                plan: .success(makeReview()),
                apply: .success(partial)
            )
        )

        XCTAssertEqual(
            fixture.run([
                "simlease", "clean", "apply", "ABC123",
                "--target", "DEVICE-1",
            ]),
            76
        )
    }

    func testTypedErrorsReturnSpecifiedCodes() throws {
        let owner = LeaseOwner(
            pid: 42,
            acquiredAt: Date(),
            cwd: "/Projects/Set",
            project: "Set",
            command: ["xcodebuild", "test"],
            source: .codex,
            threadID: "thread",
            threadTitle: "[Set] Tests"
        )
        let cases: [(CleanupServiceError, Int32)] = [
            (.plan(.missing), 73),
            (.plan(.expired), 73),
            (.plan(.invalidIntegrity), 73),
            (.inventory(.invalidDevicesJSON), 74),
            (.leaseBusy(LeaseStatus(
                state: .leased,
                owner: owner,
                waiters: [],
                error: nil
            )), 75),
        ]

        for (error, expectedCode) in cases {
            let fixture = try CleanupCLIFixture(
                stub: CleanupServiceStub(
                    plan: .failure(error),
                    apply: .failure(error)
                )
            )
            XCTAssertEqual(
                fixture.run(["simlease", "clean", "plan"]),
                expectedCode
            )
            if expectedCode == 75 {
                XCTAssertTrue(fixture.errors.value.contains("[Set] Tests"))
            }
        }
    }

    func testUsageIncludesClean() throws {
        let fixture = try CleanupCLIFixture(
            stub: CleanupServiceStub(
                plan: .success(makeReview()),
                apply: .success(makeResult())
            )
        )

        XCTAssertEqual(fixture.run(["simlease"]), 64)
        XCTAssertEqual(
            fixture.errors.value,
            "Usage: simlease <run|session|device|recover|doctor|status|name|hold|clean|update|--version>\n"
        )
    }
}

private func makeReview() -> CleanupReview {
    let device = makeTarget(kind: .device, id: "DEVICE-1")
    let runtime = makeTarget(kind: .runtime, id: "RUNTIME-1")
    let protected = ProtectedCleanupTarget(
        target: makeTarget(kind: .device, id: "BOOTED"),
        reason: .booted,
        explanation: "Device is booted"
    )
    let plan = CleanupPlan(
        id: "ABC123",
        createdAt: Date(timeIntervalSince1970: 1_000),
        expiresAt: Date(timeIntervalSince1970: 1_600),
        devices: [device],
        runtimes: [runtime],
        storage: [
            makeStorageTarget(
                id: "derivedData:/cache",
                category: .derivedData,
                action: .deletePermanently
            ),
            makeStorageTarget(
                id: "archive:/archive",
                category: .archive,
                action: .moveToTrash
            ),
        ],
        protected: [protected],
        deferred: [.simulatorRuntime],
        estimatedBytes: 300,
        availableBytesBefore: 1_000
    )
    return CleanupReview(
        plan: plan,
        protected: [protected],
        deferred: [.simulatorRuntime],
        estimatedBytes: 300
    )
}

private func makeStorageTarget(
    id: String,
    category: CleanupCategory,
    action: CleanupAction
) -> CleanupTarget {
    let path = "/" + id.replacingOccurrences(of: ":", with: "/")
    return CleanupTarget(
        kind: .filesystem,
        identifier: id,
        name: id,
        detail: path,
        category: category,
        riskTier: action == .moveToTrash ? .guarded : .rebuildable,
        action: action,
        path: path,
        runtimeIdentifier: "",
        lastUsedAt: Date(timeIntervalSince1970: 100),
        sizeBytes: 100,
        fingerprint: .filesystem(
            path: path,
            sizeBytes: 100,
            modifiedAt: Date(timeIntervalSince1970: 100)
        ),
        selectedByDefault: action == .deletePermanently
    )
}

private func makeResult() -> CleanupResult {
    CleanupResult(
        planID: "ABC123",
        items: [
            CleanupItemResult(
                target: makeTarget(kind: .device, id: "DEVICE-1"),
                outcome: .deleted,
                message: "Deleted"
            ),
        ],
        estimatedBytes: 100,
        availableBytesBefore: 1_000,
        availableBytesAfter: 1_100
    )
}

private func makeTarget(
    kind: CleanupTargetKind,
    id: String
) -> CleanupTarget {
    CleanupTarget(
        kind: kind,
        identifier: id,
        name: id,
        runtimeIdentifier: "runtime",
        lastUsedAt: kind == .device ? Date(timeIntervalSince1970: 100) : nil,
        sizeBytes: kind == .device ? 100 : nil
    )
}

private final class CleanupServiceStub:
    CleanupServicing,
    @unchecked Sendable
{
    let plan: Result<CleanupReview, Error>
    let apply: Result<CleanupResult, Error>
    private(set) var selectedTargetIDs = Set<String>()

    init(
        plan: Result<CleanupReview, Error>,
        apply: Result<CleanupResult, Error>
    ) {
        self.plan = plan
        self.apply = apply
    }

    func createPlan() throws -> CleanupReview {
        try plan.get()
    }

    func apply(
        planID: String,
        selectedTargetIDs: Set<String>
    ) throws -> CleanupResult {
        self.selectedTargetIDs = selectedTargetIDs
        return try apply.get()
    }
}

private final class CleanupCLIFixture {
    let root: URL
    let output = CleanupLockedText()
    let errors = CleanupLockedText()
    let configuration: CLIConfiguration

    init(stub: CleanupServiceStub) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = output
        let errors = errors
        configuration = CLIConfiguration(
            paths: LeasePaths(root: root),
            timing: .production,
            standardOutput: { output.append($0) },
            standardError: { errors.append($0) },
            cleanupService: stub
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func run(_ arguments: [String]) -> Int32 {
        SimLeaseCLI.run(
            arguments: arguments,
            environment: [:],
            configuration: configuration
        )
    }
}

private final class CleanupLockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    var value: String {
        lock.withLock { text }
    }

    func append(_ value: String) {
        lock.withLock { text += value }
    }

    func clear() {
        lock.withLock { text = "" }
    }
}
