import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuCore

final class MenuDisplayStateTests: XCTestCase {
    func testCrashBlockTakesPriorityOverIncompleteAuditWithoutLosingLeaseState() {
        let block = CrashLoopTrigger(deviceID: "11111111-1111-4111-8111-111111111111", scopeID: "scope", processName: "App", signature: "build", occurredAt: Date())
        let status = LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, activity: SimulatorActivityReport(uninspectedProcessCount: 2), crashBlocks: [block])
        let display = MenuDisplayState(status: status, now: Date())
        XCTAssertEqual(display.menuTitle, "Simulator · Crash blocked")
        XCTAssertEqual(display.crashBlocks, [block])
        XCTAssertEqual(display.kind, .free)
    }
    func testLeasedStateUsesTitleAndWaiters() {
        let status = LeaseStatus(
            state: .leased,
            owner: owner(
                acquiredAt: Date(timeIntervalSince1970: 100),
                threadID: "019faaef-c552-7933",
                threadTitle: "[AnimAtlas] Onboarding"
            ),
            waiters: [
                waiter(
                    title: "[Set] Release validation",
                    waitingSince: Date(timeIntervalSince1970: 202)
                ),
            ],
            error: nil
        )

        let state = MenuDisplayState(
            status: status,
            now: Date(timeIntervalSince1970: 502)
        )

        XCTAssertEqual(state.menuTitle, "Simulator · 06:42")
        XCTAssertEqual(state.ownerName, "[AnimAtlas] Onboarding")
        XCTAssertEqual(
            state.waiters,
            [
                WaiterDisplayItem(
                    id: "waiter-1",
                    name: "[Set] Release validation",
                    projectAndSource: "Set · Codex",
                    elapsed: "05:00",
                    command: "xcrun simctl list",
                    threadID: "019fbb00-c552-7933",
                    cwd: "/tmp/Set"
                ),
            ]
        )
        XCTAssertEqual(state.kind, .leased)
    }

    func testMissingTitleUsesEightCharacterThreadID() {
        let status = LeaseStatus(
            state: .leased,
            owner: owner(threadID: "019faaef-c552-7933", threadTitle: nil),
            waiters: [],
            error: nil
        )

        XCTAssertEqual(
            MenuDisplayState(status: status, now: Date()).ownerName,
            "019faaef"
        )
    }

    func testFreeAndErrorLabelsAreStable() {
        XCTAssertEqual(MenuDisplayState.free.menuTitle, "Simulator · Free")
        XCTAssertEqual(
            MenuDisplayState.metadataError("owner.json is corrupt").menuTitle,
            "Simulator · Error"
        )
    }

    func testKindsMapToApprovedColorNames() {
        XCTAssertEqual(StatusTheme.colorName(for: .free), "green")
        XCTAssertEqual(StatusTheme.colorName(for: .leased), "orange")
        XCTAssertEqual(StatusTheme.colorName(for: .metadataError), "red")
    }

    func testManualHoldUsesStableIdentity() {
        let status = LeaseStatus(
            state: .leased,
            owner: LeaseOwner(
                pid: 1,
                acquiredAt: Date(),
                cwd: "/tmp/SimLease",
                project: "SimLease",
                command: ["simlease", "hold"],
                source: .manualXcode,
                threadID: nil,
                threadTitle: "Manual smoke"
            ),
            waiters: [],
            error: nil
        )

        XCTAssertEqual(
            MenuDisplayState(status: status, now: Date()).ownerName,
            "Manual Xcode · SimLease"
        )
    }

    private func owner(
        acquiredAt: Date = Date(),
        threadID: String? = nil,
        threadTitle: String? = nil
    ) -> LeaseOwner {
        LeaseOwner(
            pid: 1,
            acquiredAt: acquiredAt,
            cwd: "/tmp/AnimAtlas",
            project: "AnimAtlas",
            command: ["xcodebuild", "test"],
            source: .codex,
            threadID: threadID,
            threadTitle: threadTitle
        )
    }

    private func waiter(
        title: String?,
        waitingSince: Date = Date()
    ) -> LeaseWaiter {
        LeaseWaiter(
            id: "waiter-1",
            pid: 2,
            waitingSince: waitingSince,
            cwd: "/tmp/Set",
            project: "Set",
            command: ["xcrun", "simctl", "list"],
            source: .codex,
            threadID: "019fbb00-c552-7933",
            threadTitle: title
        )
    }
}
