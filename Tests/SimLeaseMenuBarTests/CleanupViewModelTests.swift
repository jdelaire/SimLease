import Foundation
import XCTest
import SimLeaseCore
@testable import SimLeaseMenuCore

@MainActor
final class CleanupViewModelTests: XCTestCase {
    func testExactConfirmationEnablesApplyAndPublishesResult() async {
        let review = cleanupReview()
        let result = cleanupResult()
        let stub = CleanupMenuStub(review: .success(review), result: .success(result))
        let model = CleanupViewModel(provider: stub)

        await model.load()
        XCTAssertEqual(model.state, .review(review))
        XCTAssertEqual(model.selectedTargetIDs, ["DEVICE-1"])
        XCTAssertEqual(model.selectedDeleteBytes, 100)
        XCTAssertEqual(model.selectedTrashCount, 0)
        XCTAssertFalse(model.canApply)
        model.confirmationText = "ABC123"
        XCTAssertTrue(model.canApply)
        await model.apply()
        XCTAssertEqual(model.state, .result(result))
        let applied = await stub.appliedTargetIDs()
        XCTAssertEqual(applied, ["DEVICE-1"])
    }

    func testGuardedTargetStartsUncheckedAndCanBeSelected() async {
        let model = CleanupViewModel(
            provider: CleanupMenuStub(
                review: .success(cleanupReview()),
                result: .success(cleanupResult())
            )
        )

        await model.load()
        model.setSelected(true, targetID: "ARCHIVE-1")

        XCTAssertEqual(
            model.selectedTargetIDs,
            ["DEVICE-1", "ARCHIVE-1"]
        )
        XCTAssertEqual(model.selectedTrashCount, 1)
        XCTAssertEqual(model.primaryActionTitle, "Delete 100 bytes + Trash 1 Item")

        model.setSelected(false, targetID: "DEVICE-1")
        XCTAssertEqual(model.selectedTargetIDs, ["ARCHIVE-1"])
        XCTAssertEqual(model.primaryActionTitle, "Move 1 Item to Trash")
    }

    func testWrongCaseAndEmptyReviewNeverEnableApply() async {
        let model = CleanupViewModel(
            provider: CleanupMenuStub(
                review: .success(cleanupReview()),
                result: .success(cleanupResult())
            )
        )
        await model.load()
        model.confirmationText = "abc123"
        XCTAssertFalse(model.canApply)

        let empty = CleanupViewModel(
            provider: CleanupMenuStub(
                review: .success(CleanupReview(
                    plan: nil,
                    protected: [],
                    estimatedBytes: 0
                )),
                result: .success(cleanupResult())
            )
        )
        await empty.load()
        empty.confirmationText = "ABC123"
        XCTAssertFalse(empty.canApply)
    }

    func testLoadErrorPreservesExactLocalizedMessage() async {
        let model = CleanupViewModel(
            provider: CleanupMenuStub(
                review: .failure(CleanupMenuTestError("literal load error")),
                result: .success(cleanupResult())
            )
        )

        await model.load()

        XCTAssertEqual(model.state, .error("literal load error"))
        XCTAssertEqual(model.error, "literal load error")
    }

    func testApplyErrorReturnsToReviewWithErrorText() async {
        let review = cleanupReview()
        let model = CleanupViewModel(
            provider: CleanupMenuStub(
                review: .success(review),
                result: .failure(CleanupMenuTestError("literal apply error"))
            )
        )
        await model.load()
        model.confirmationText = "ABC123"

        await model.apply()

        XCTAssertEqual(model.state, .review(review))
        XCTAssertEqual(model.error, "literal apply error")
    }
}

private actor CleanupMenuStub: MenuCleanupProviding {
    let review: Result<CleanupReview, Error>
    let result: Result<CleanupResult, Error>
    private var appliedIDs = Set<String>()

    init(
        review: Result<CleanupReview, Error>,
        result: Result<CleanupResult, Error>
    ) {
        self.review = review
        self.result = result
    }

    func plan() async throws -> CleanupReview {
        try review.get()
    }

    func apply(id: String) async throws -> CleanupResult {
        try result.get()
    }

    func apply(
        id: String,
        selectedTargetIDs: Set<String>
    ) async throws -> CleanupResult {
        appliedIDs = selectedTargetIDs
        return try result.get()
    }

    func appliedTargetIDs() -> Set<String> {
        appliedIDs
    }
}

private struct CleanupMenuTestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private func cleanupReview() -> CleanupReview {
    let target = cleanupTarget()
    let plan = CleanupPlan(
        id: "ABC123",
        createdAt: Date(timeIntervalSince1970: 1_000),
        expiresAt: Date(timeIntervalSince1970: 1_600),
        devices: [target],
        runtimes: [],
        storage: [guardedTarget()],
        protected: [],
        estimatedBytes: 100,
        availableBytesBefore: 1_000
    )
    return CleanupReview(
        plan: plan,
        protected: [],
        estimatedBytes: 100
    )
}

private func guardedTarget() -> CleanupTarget {
    CleanupTarget(
        kind: .filesystem,
        identifier: "ARCHIVE-1",
        name: "Archive",
        detail: "/tmp/Archive.xcarchive",
        category: .archive,
        riskTier: .guarded,
        action: .moveToTrash,
        path: "/tmp/Archive.xcarchive",
        runtimeIdentifier: "",
        lastUsedAt: Date(timeIntervalSince1970: 100),
        sizeBytes: 200,
        fingerprint: .filesystem(
            path: "/tmp/Archive.xcarchive",
            sizeBytes: 200,
            modifiedAt: Date(timeIntervalSince1970: 100)
        ),
        selectedByDefault: false
    )
}

private func cleanupResult() -> CleanupResult {
    CleanupResult(
        planID: "ABC123",
        items: [
            CleanupItemResult(
                target: cleanupTarget(),
                outcome: .deleted,
                message: "Deleted"
            ),
        ],
        estimatedBytes: 100,
        availableBytesBefore: 1_000,
        availableBytesAfter: 1_100
    )
}

private func cleanupTarget() -> CleanupTarget {
    CleanupTarget(
        kind: .device,
        identifier: "DEVICE-1",
        name: "Device",
        runtimeIdentifier: "runtime",
        lastUsedAt: Date(timeIntervalSince1970: 100),
        sizeBytes: 100
    )
}
