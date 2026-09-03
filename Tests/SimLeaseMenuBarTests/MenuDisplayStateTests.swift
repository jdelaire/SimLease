import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuCore

final class MenuDisplayStateTests: XCTestCase {
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

    func testLaneSummariesMapToDisplayItems() {
        let status = LeaseStatus(
            state: .leased,
            owner: owner(),
            waiters: [],
            lanes: [
                LeaseLaneSummary(
                    laneID: "lane-1",
                    slot: 1,
                    project: "ExplorerDex",
                    threadID: "thread-1",
                    threadTitle: "Simulator validation",
                    udid: "UDID-1",
                    deviceTypeName: "iPhone 17 Pro",
                    runtimeName: "iOS 27.0",
                    lastActivityAt: Date(timeIntervalSince1970: 400),
                    recoveryRequired: false
                ),
                LeaseLaneSummary(
                    laneID: "lane-2",
                    slot: 2,
                    project: "Set",
                    threadID: nil,
                    threadTitle: nil,
                    udid: "UDID-2",
                    deviceTypeName: "iPhone 17",
                    runtimeName: "iOS 26.0",
                    lastActivityAt: Date(timeIntervalSince1970: 100),
                    recoveryRequired: true
                ),
            ],
            error: nil
        )

        let state = MenuDisplayState(
            status: status,
            now: Date(timeIntervalSince1970: 502)
        )

        XCTAssertEqual(
            state.lanes,
            [
                LaneDisplayItem(
                    id: "lane-1",
                    name: "Simulator validation",
                    detail: "iPhone 17 Pro · iOS 27.0",
                    elapsed: "01:42",
                    udid: "UDID-1",
                    recoveryRequired: false
                ),
                LaneDisplayItem(
                    id: "lane-2",
                    name: "Set",
                    detail: "iPhone 17 · iOS 26.0",
                    elapsed: "06:42",
                    udid: "UDID-2",
                    recoveryRequired: true
                ),
            ]
        )
        XCTAssertEqual(MenuDisplayState.free.lanes, [])
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
