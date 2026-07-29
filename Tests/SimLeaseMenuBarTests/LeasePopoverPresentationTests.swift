import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuBar
@testable import SimLeaseMenuCore

final class LeasePopoverPresentationTests: XCTestCase {
    @MainActor
    func testCleanupWindowPresentationOpensThenActivatesApplication() {
        var events: [String] = []

        presentCleanupWindow(
            openWindow: { events.append("open") },
            activateApplication: { events.append("activate") }
        )

        XCTAssertEqual(events, ["open", "activate"])
    }

    func testFreeStateExplainsThatTestingCanStart() {
        let presentation = LeasePopoverPresentation(state: .free)

        XCTAssertEqual(presentation.title, "Simulator available")
        XCTAssertEqual(
            presentation.description,
            "Ready for simulator testing."
        )
    }

    func testMetadataErrorPreservesExactMessage() {
        let presentation = LeasePopoverPresentation(
            state: .metadataError("metadata exploded")
        )

        XCTAssertEqual(presentation.title, "Simulator status error")
        XCTAssertEqual(presentation.description, "metadata exploded")
    }

    func testLeasedStateUsesProjectAndSource() {
        let state = MenuDisplayState(
            status: LeaseStatus(
                state: .leased,
                owner: LeaseOwner(
                    pid: 1,
                    acquiredAt: Date(timeIntervalSince1970: 100),
                    cwd: "/tmp/SimLease",
                    project: "SimLease",
                    command: ["xcodebuild", "test"],
                    source: .codex,
                    threadID: nil,
                    threadTitle: "Owner task"
                ),
                waiters: [],
                error: nil
            ),
            now: Date(timeIntervalSince1970: 102)
        )

        let presentation = LeasePopoverPresentation(state: state)

        XCTAssertEqual(presentation.title, "Simulator in use")
        XCTAssertEqual(presentation.description, "SimLease · Codex")
    }
}
