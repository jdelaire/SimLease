import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuCore

final class VisualModelsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    func testDashboardSummarizesJobsWaitsLanesGateAndCrashes() {
        let since = now.addingTimeInterval(-3600)
        let report = HistoryReport(
            since: since, laneLimit: 2,
            jobs: [
                JobRecord(project: "ExplorerDex", seconds: 600, endedAt: now.addingTimeInterval(-1800), lane: 0, waitSeconds: 60),
                JobRecord(project: "set", seconds: 900, endedAt: now.addingTimeInterval(-600), lane: 1, waitSeconds: 300),
                JobRecord(project: "ExplorerDex", seconds: 300, endedAt: now, lane: 0, waitSeconds: 120),
            ],
            samples: [
                HeadroomRecord(at: since, memoryFreePercent: 60, cpuIdlePercent: 50, load: 4, lanesBusy: 1, laneLimit: 2, gateOpen: true),
                HeadroomRecord(at: since.addingTimeInterval(60), memoryFreePercent: 38, cpuIdlePercent: 10, load: 20, lanesBusy: 2, laneLimit: 2, gateOpen: false),
                HeadroomRecord(at: since.addingTimeInterval(120), memoryFreePercent: 61, cpuIdlePercent: 55, load: 5, lanesBusy: 1, laneLimit: 2, gateOpen: true),
                HeadroomRecord(at: since.addingTimeInterval(180), memoryFreePercent: 62, cpuIdlePercent: 52, load: 5, lanesBusy: 1, laneLimit: 2, gateOpen: true),
            ],
            crashes: [
                HistoryReport.Crash(deviceID: "AAA", processName: "ExplorerDex", occurredAt: now.addingTimeInterval(-2000)),
                HistoryReport.Crash(deviceID: "AAA", processName: "ExplorerDex", occurredAt: now.addingTimeInterval(-1990)),
            ],
            blockedDeviceIDs: ["AAA"], deviceNames: ["AAA": "iPhone 18 Pro · iOS 27.2"]
        )
        let summary = DashboardSummary(report: report, now: now)
        XCTAssertEqual(summary.jobsFinished, 3)
        XCTAssertEqual(summary.medianWaitSeconds, 120)
        XCTAssertEqual(summary.extraLaneShare ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(summary.gateClosedShare, 0.25)
        XCTAssertEqual(summary.closedIntervals.count, 1)
        XCTAssertEqual(summary.crashBlocks, 1)
        XCTAssertEqual(summary.projects.map(\.project), ["ExplorerDex", "set"])
        XCTAssertEqual(summary.projects.first?.crashes, 2)
        XCTAssertEqual(summary.timeline.first?.crashes, 2)
        XCTAssertEqual(summary.heat.map(\.count), [2])
        XCTAssertEqual(summary.heat.first?.device, "iPhone 18 Pro · iOS 27.2")
    }

    func testLaneBarsAndMenuBarIconFollowLaneState() {
        let first = owner(project: "ExplorerDex", started: now.addingTimeInterval(-900))
        let status = LeaseStatus(
            state: .leased, owner: first,
            waiters: [
                LeaseWaiter(id: "all", pid: 3, waitingSince: now.addingTimeInterval(-300), cwd: "/tmp", project: "thai-srs", command: [], source: .terminal, threadID: nil, threadTitle: nil, exclusive: true),
                LeaseWaiter(id: "dev", pid: 4, waitingSince: now.addingTimeInterval(-200), cwd: "/tmp", project: "Wat Kham", command: [], source: .terminal, threadID: nil, threadTitle: nil, deviceIDs: ["BBB"]),
            ],
            error: nil, typicalDurations: ["ExplorerDex": 600],
            lanes: [LaneStatus(lane: 0, owner: first, deviceIDs: ["BBB"], exclusive: false)],
            laneLimit: 2, gate: LaneGateStatus(open: false, reason: "CPU busy, 10% idle", memoryFreePercent: 60, cpuIdlePercent: 10, load: 30, cpus: 10)
        )
        let state = MenuDisplayState(status: status, now: now)
        XCTAssertEqual(state.laneBars.map(\.kind), [.running, .closed, .off])
        XCTAssertEqual(state.laneBars.first?.overrun, true)
        XCTAssertEqual(state.waiters.map(\.reason), ["needs all lanes", "waiting for BBB"])
        XCTAssertEqual(state.headroom?.cpuIdlePercent, 10)
        let icon = MenuBarIconState(state: state)
        XCTAssertEqual(icon.shape, .lanes([.busy(slot: ProjectPalette.slot(for: "ExplorerDex")), .closed]))
        XCTAssertEqual(icon.text, "1 · 2 waiting")
    }

    func testSingleLaneIconShowsProgressAndFreeOrCrashStates() {
        let job = owner(project: "Set", started: now.addingTimeInterval(-120))
        let single = MenuDisplayState(status: LeaseStatus(state: .leased, owner: job, waiters: [], error: nil, typicalDurations: ["Set": 480]), now: now)
        XCTAssertEqual(MenuBarIconState(state: single).shape, .ring(slot: ProjectPalette.slot(for: "Set"), fraction: 0.25))
        XCTAssertEqual(MenuBarIconState(state: .free).shape, .free)
        let crash = MenuDisplayState(status: LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, crashBlocks: [CrashLoopTrigger(deviceID: "AAA", scopeID: "s", processName: "App", signature: "x", occurredAt: now)]), now: now)
        XCTAssertEqual(MenuBarIconState(state: crash).shape, .crash)
        XCTAssertEqual(ProjectPalette.slot(for: "ExplorerDex"), ProjectPalette.slot(for: " explorerdex "))
    }

    private func owner(project: String, started: Date) -> LeaseOwner {
        LeaseOwner(pid: 1, acquiredAt: started, cwd: "/tmp/\(project)", project: project, command: ["xcodebuild", "test"], source: .terminal, threadID: nil, threadTitle: nil)
    }
}
