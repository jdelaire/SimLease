import Foundation
import XCTest
import SimLeaseCore
@testable import SimLeaseMenuCore

final class MenuCleanupProviderTests: XCTestCase {
    func testRunsOnlyPlanAndApplyJSONCommandsAndAcceptsPartialExit() async throws {
        let review = providerReview()
        let result = providerResult()
        let runner = MenuCleanupRunner(outputs: [
            CleanupCommandOutput(
                exitCode: 0,
                stdout: String(
                    decoding: try JSONEncoder.simLease.encode(review),
                    as: UTF8.self
                ),
                stderr: ""
            ),
            CleanupCommandOutput(
                exitCode: 76,
                stdout: String(
                    decoding: try JSONEncoder.simLease.encode(result),
                    as: UTF8.self
                ),
                stderr: ""
            ),
        ])
        let provider = CLICleanupProvider(
            executableURL: URL(fileURLWithPath: "/test/simlease"),
            environment: ["KEEP": "1"],
            runner: runner
        )

        let loadedReview = try await provider.plan()
        let loadedResult = try await provider.apply(
            id: "ABC123",
            selectedTargetIDs: ["RUNTIME-1", "ARCHIVE-1"]
        )
        XCTAssertEqual(loadedReview, review)
        XCTAssertEqual(loadedResult, result)
        XCTAssertEqual(runner.arguments, [
            ["clean", "plan", "--json"],
            [
                "clean", "apply", "ABC123",
                "--target", "ARCHIVE-1",
                "--target", "RUNTIME-1",
                "--json",
            ],
        ])
    }

    func testCommandFailurePreservesExactStderr() async {
        let runner = MenuCleanupRunner(outputs: [
            CleanupCommandOutput(
                exitCode: 75,
                stdout: "",
                stderr: "literal busy owner\n"
            ),
        ])
        let provider = CLICleanupProvider(
            executableURL: URL(fileURLWithPath: "/test/simlease"),
            runner: runner
        )

        do {
            _ = try await provider.plan()
            XCTFail("Expected command failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "literal busy owner")
        }
    }
}

private final class MenuCleanupRunner:
    CleanupCommandRunning,
    @unchecked Sendable
{
    private var outputs: [CleanupCommandOutput]
    private(set) var arguments: [[String]] = []

    init(outputs: [CleanupCommandOutput]) {
        self.outputs = outputs
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> CleanupCommandOutput {
        self.arguments.append(arguments)
        return outputs.removeFirst()
    }
}

private func providerReview() -> CleanupReview {
    CleanupReview(
        plan: CleanupPlan(
            id: "ABC123",
            createdAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_600),
            devices: [],
            runtimes: [providerTarget()],
            protected: [],
            estimatedBytes: 100,
            availableBytesBefore: 1_000
        ),
        protected: [],
        estimatedBytes: 100
    )
}

private func providerResult() -> CleanupResult {
    CleanupResult(
        planID: "ABC123",
        items: [
            CleanupItemResult(
                target: providerTarget(),
                outcome: .skipped,
                message: "Runtime became active"
            ),
        ],
        estimatedBytes: 100,
        availableBytesBefore: 1_000,
        availableBytesAfter: 1_000
    )
}

private func providerTarget() -> CleanupTarget {
    CleanupTarget(
        kind: .runtime,
        identifier: "RUNTIME-1",
        name: "Runtime",
        runtimeIdentifier: "runtime",
        lastUsedAt: nil,
        sizeBytes: 100
    )
}
