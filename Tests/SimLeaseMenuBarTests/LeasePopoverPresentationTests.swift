import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuBar
@testable import SimLeaseMenuCore

final class LeasePopoverPresentationTests: XCTestCase {
    @MainActor
    func testQuitActionTerminatesApplication() {
        var didTerminate = false

        performQuitAction {
            didTerminate = true
        }

        XCTAssertTrue(didTerminate)
    }

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

        XCTAssertEqual(presentation.title, "Simulator free")
        XCTAssertEqual(presentation.description, "Ready for simulator work")
    }

    func testMetadataErrorPreservesExactMessage() {
        let presentation = LeasePopoverPresentation(
            state: .metadataError("metadata exploded")
        )

        XCTAssertEqual(presentation.title, "Status unavailable")
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

        XCTAssertEqual(presentation.title, "Simulator busy")
        XCTAssertEqual(presentation.description, "Nobody waiting")
        XCTAssertEqual(state.ownerHeadline, "Owner task")
        XCTAssertEqual(state.ownerSubheadline, "SimLease · Codex")
    }
}
