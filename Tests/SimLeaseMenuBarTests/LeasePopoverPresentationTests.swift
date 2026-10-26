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
        XCTAssertEqual(presentation.symbolName, "checkmark")
        XCTAssertEqual(presentation.color, ProjectColors.good)
    }

    func testFreeLaneCountsBlockedDevicesWithoutRequiringInventory() {
        let ids = (1...4).map { "AABBCCDD-0000-4000-8000-00000000000\($0)" }
        let blocks = ids.map { block(deviceID: $0) } + [block(deviceID: ids[0].lowercased())]
        let inventory = ids.map { SimulatorUsage(id: $0, name: "Preview", runtime: "iOS", state: "Shutdown", reservation: .unreserved) }

        for devices: [SimulatorUsage]? in [nil, inventory] {
            let state = MenuDisplayState(status: LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, crashBlocks: blocks, devices: devices), now: now)
            let presentation = LeasePopoverPresentation(state: state)

            XCTAssertEqual(presentation.title, "Lane free")
            XCTAssertEqual(presentation.description, "4 simulators crash blocked. See alerts below.")
            XCTAssertEqual(presentation.symbolName, "exclamationmark.triangle.fill")
            XCTAssertEqual(presentation.color, ProjectColors.warning)
            XCTAssertEqual(state.kind, .free)
        }
    }

    func testVerifiedRecoveryPreservesIndependentCrashWarning() {
        let crash = block(deviceID: "device")
        let health = SimulatorHealthStatus(recoveries: [AutomaticRecoveryRecord(deviceID: "device", state: .recovered, detail: "Stable services and final shutdown verified.", updatedAt: now)])
        let state = MenuDisplayState(status: LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, crashBlocks: [crash], simulatorHealth: health), now: now)
        let presentation = LeasePopoverPresentation(state: state)

        XCTAssertEqual(presentation.title, "Lane free")
        XCTAssertEqual(presentation.description, "1 simulator crash blocked. See alerts below.")
        XCTAssertEqual(presentation.color, ProjectColors.warning)
        XCTAssertTrue(state.alerts.contains { $0.title == "Simulator restart verified" })
    }

    func testFilteredInfrastructureAndHistoryDoNotBecomeManualHeaderWarnings() {
        let crash = block(deviceID: "device")
        for phase: AutomaticRecoveryPhase in [.verifying, .history] {
            let health = SimulatorHealthStatus(recoveries: [AutomaticRecoveryRecord(deviceID: "device", state: phase, detail: "Recovery status", updatedAt: now)], infrastructureBlocks: [crash])
            let state = MenuDisplayState(status: LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, crashBlocks: [crash], simulatorHealth: health), now: now)
            let presentation = LeasePopoverPresentation(state: state)

            XCTAssertEqual(presentation.title, "Simulator free")
            XCTAssertTrue(state.crashBlocks.isEmpty)
        }
    }

    func testCrashBlocksDoNotHideRunningWorkOrMetadataErrors() {
        let owner = LeaseOwner(pid: 1, acquiredAt: now, cwd: "/Projects/Preview", project: "Preview", command: [], source: .terminal, threadID: nil, threadTitle: "Preview work")
        let waiter = LeaseWaiter(id: "queued", pid: 2, waitingSince: now, cwd: "/Projects/Next", project: "Next", command: [], source: .terminal, threadID: nil, threadTitle: "Next work")
        let blocks = [block(deviceID: "other-device")]
        let leased = MenuDisplayState(status: LeaseStatus(state: .leased, owner: owner, waiters: [waiter], error: nil, crashBlocks: blocks), now: now)
        let legacyError = MenuDisplayState(status: LeaseStatus(state: .metadataError, owner: nil, waiters: [], error: "metadata exploded", crashBlocks: blocks), now: now)
        let mixedError = MenuDisplayState(status: LeaseStatus(state: .metadataError, owner: nil, waiters: [waiter], error: "unresolved", crashBlocks: blocks, lanes: [LaneStatus(lane: 1, owner: owner, deviceIDs: [], exclusive: false)], laneLimit: 3, laneErrors: [LaneStatusError(lane: 0, message: "unresolved")]), now: now)

        XCTAssertEqual(LeasePopoverPresentation(state: leased).title, "Simulator busy")
        XCTAssertEqual(LeasePopoverPresentation(state: leased).description, "1 waiting")
        XCTAssertEqual(LeasePopoverPresentation(state: leased).symbolName, "hourglass")
        XCTAssertEqual(LeasePopoverPresentation(state: legacyError).title, "Status unavailable")
        XCTAssertEqual(LeasePopoverPresentation(state: legacyError).description, "metadata exploded")
        XCTAssertEqual(LeasePopoverPresentation(state: legacyError).color, ProjectColors.critical)
        XCTAssertEqual(LeasePopoverPresentation(state: mixedError).title, "Lanes need attention")
        XCTAssertEqual(LeasePopoverPresentation(state: mixedError).description, "1 running · 1 waiting")
    }

    private let now = Date(timeIntervalSince1970: 10_000)

    private func block(deviceID: String) -> CrashLoopTrigger {
        CrashLoopTrigger(deviceID: deviceID, scopeID: "scope", processName: "App", signature: "build", occurredAt: now)
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
