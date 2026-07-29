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
        XCTAssertFalse(model.canApply)
        model.confirmationText = "ABC123"
        XCTAssertTrue(model.canApply)
        await model.apply()
        XCTAssertEqual(model.state, .result(result))
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
