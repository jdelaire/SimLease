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
                    cwd: "/tmp/Set",
                    waited: "waiting 5 min",
                    reason: "needs all lanes",
                    project: "Set"
                ),
            ]
        )
        XCTAssertEqual(state.kind, .leased)
    }

    func testDeviceRowsShowOwnerQueueAndOutsideWork() {
        let id = "11111111-1111-4111-8111-111111111111"
        let other = "22222222-2222-4222-8222-222222222222"
        var queued = waiter(title: "[Set] Release validation")
        queued = LeaseWaiter(id: queued.id, pid: queued.pid, waitingSince: queued.waitingSince, cwd: queued.cwd, project: queued.project, command: queued.command, source: queued.source, threadID: queued.threadID, threadTitle: queued.threadTitle, deviceIDs: [id.lowercased()])
        let status = LeaseStatus(
            state: .leased,
            owner: owner(threadTitle: "[AnimAtlas] Onboarding"),
            waiters: [queued],
            error: nil,
            activity: SimulatorActivityReport(activities: [SimulatorActivity(process: ProcessReference(pid: 42, startMicroseconds: 1), tool: "simctl", kind: .unmanaged, deviceIDs: [other])]),
            crashBlocks: [CrashLoopTrigger(deviceID: other, scopeID: "scope", processName: "App", signature: "sig", occurredAt: Date())],
            devices: [
                SimulatorUsage(id: id, name: "iPhone 17 Pro", runtime: "iOS 27.2", state: "Booted", reservation: .owned),
                SimulatorUsage(id: other, name: "iPhone Air", runtime: "iOS 27.1", state: "Booted", reservation: .unreserved),
            ]
        )

        let devices = MenuDisplayState(status: status, now: Date()).devices

        XCTAssertEqual(devices, [
            DeviceDisplayItem(id: id, name: "iPhone 17 Pro", detail: "iOS 27.2 · Booted", reservation: .owned, user: "[AnimAtlas] Onboarding · shuts down after", waiting: ["[Set] Release validation"], unmanaged: [], crashBlocked: false, runtime: "iOS 27.2", state: "Booted", ownerProject: "AnimAtlas"),
            DeviceDisplayItem(id: other, name: "iPhone Air", detail: "iOS 27.1 · Booted", reservation: .unreserved, user: "No SimLease reservation", waiting: [], unmanaged: ["simctl · PID 42"], crashBlocked: true, runtime: "iOS 27.1", state: "Booted"),
        ])
        XCTAssertNil(MenuDisplayState(status: LeaseStatus(state: .free, owner: nil, waiters: [], error: nil), now: Date()).devices)
    }

    func testWarmRowShowsIdleMinutesAndCanShutDown() {
        let id = "11111111-1111-4111-8111-111111111111"
        let now = Date(timeIntervalSince1970: 1_000)
        let status = LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, devices: [
            SimulatorUsage(id: id, name: "iPhone 18 Pro", runtime: "iOS 27.2", state: "Booted", reservation: .warm, warmSince: now.addingTimeInterval(-185)),
        ])
        let device = MenuDisplayState(status: status, now: now).devices?.first
        XCTAssertEqual(device?.user, "Kept warm by SimLease · idle 3 min")
        XCTAssertEqual(device?.canShutDown, true)
    }

    func testQueueEstimatesChainTypicalDurationsUntilOneIsUnknown() {
        let now = Date(timeIntervalSince1970: 10_000)
        let queued = ["B", "C", "D"].enumerated().map { index, project in
            LeaseWaiter(id: project, pid: 2, waitingSince: now.addingTimeInterval(Double(index)), cwd: "/tmp/\(project)", project: project, command: [], source: .codex, threadID: nil, threadTitle: project)
        }
        let status = LeaseStatus(
            state: .leased, owner: owner(acquiredAt: now.addingTimeInterval(-120), threadTitle: "A"), waiters: queued.reversed(), error: nil,
            typicalDurations: ["AnimAtlas": 600, "B": 300, "D": 60], nativeIdleSince: now.addingTimeInterval(-900)
        )
        let state = MenuDisplayState(status: status, now: now)
        XCTAssertEqual(state.typicalDuration, "usually ≈ 10 min")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: state.waiters.map { ($0.id, $0.estimate) }), ["B": "starts in ≈ 8 min", "C": "starts in ≈ 13 min", "D": nil])
        XCTAssertEqual(state.nativeIdle, "No native device commands for 15 min. Finish the session if it is done.")
        let recent = LeaseStatus(state: .leased, owner: owner(threadTitle: "A"), waiters: [], error: nil, nativeIdleSince: now.addingTimeInterval(-300))
        XCTAssertNil(MenuDisplayState(status: recent, now: now).nativeIdle)
    }

    func testAlertsNameTheBlockedDeviceAndRankBySeverity() {
        let blocked = "11111111-1111-4111-8111-111111111111"
        let status = LeaseStatus(
            state: .free, owner: nil, waiters: [], error: nil,
            activity: SimulatorActivityReport(activities: [SimulatorActivity(process: ProcessReference(pid: 9, startMicroseconds: 1), tool: "simctl", kind: .unmanaged, deviceIDs: [])], uninspectedProcessCount: 1),
            crashBlocks: [CrashLoopTrigger(deviceID: blocked, scopeID: "scope", processName: "ExplorerDex", signature: "sig", occurredAt: Date())],
            devices: [SimulatorUsage(id: blocked, name: "iPhone 18 Pro", runtime: "iOS 27.2", state: "Shutdown", reservation: .unreserved)]
        )
        let alerts = MenuDisplayState(status: status, now: Date()).alerts
        XCTAssertEqual(alerts.map(\.id), ["crash-\(blocked)", "unmanaged", "audit"])
        XCTAssertEqual(alerts.first?.acknowledgeDeviceID, blocked)
        XCTAssertEqual(alerts.first?.copyText, "simlease device acknowledge --device \(blocked)")
    }

    func testQueueRowsUseProjectHeadlinesArrivalOrderAndTargets() {
        let now = Date(timeIntervalSince1970: 10_000)
        let target = "0C4D6F06-8ADF-4785-BD18-6A0F566689A8"
        let status = LeaseStatus(
            state: .leased, owner: owner(threadTitle: "A"),
            waiters: [
                LeaseWaiter(id: "late", pid: 3, waitingSince: now.addingTimeInterval(-60), cwd: "/tmp/thai", project: "thai-srs", command: [], source: .codex, threadID: nil, threadTitle: "Duo slide"),
                LeaseWaiter(id: "early", pid: 2, waitingSince: now.addingTimeInterval(-660), cwd: "/tmp/set", project: "set", command: [], source: .terminal, threadID: nil, threadTitle: nil, deviceIDs: [target]),
            ],
            error: nil,
            devices: [SimulatorUsage(id: target, name: "Set Smoke iPhone 17 Pro", runtime: "iOS 27.0", state: "Shutdown", reservation: .unreserved)]
        )
        let waiters = MenuDisplayState(status: status, now: now).waiters
        XCTAssertEqual(waiters.map(\.headline), ["set", "Duo slide"])
        XCTAssertEqual(waiters.map(\.subheadline), ["Terminal", "thai-srs · Codex"])
        XCTAssertEqual(waiters.first?.waited, "waiting 11 min")
        XCTAssertEqual(waiters.first?.targets, ["Set Smoke iPhone 17 Pro · iOS 27.0"])
    }

    func testStaleRuntimeRaisesAlertAndMarksDevices() {
        let id = "11111111-1111-4111-8111-111111111111"
        let runtime = StaleRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", version: "27.2", build: "24B5089g", sdkBuild: "24B5109a")
        let status = LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, devices: [
            SimulatorUsage(id: id, name: "iPhone 18 Pro", runtime: "iOS 27.2", state: "Booted", reservation: .unreserved, runtimeStale: true),
        ], staleRuntimes: [runtime])
        let state = MenuDisplayState(status: status, now: Date())
        XCTAssertEqual(state.alerts.map(\.title), ["iOS 27.2 runtime is older than Xcode"])
        XCTAssertEqual(state.alerts.first?.copyText, "xcodebuild -downloadPlatform iOS")
        XCTAssertEqual(state.devices?.first?.runtimeStale, true)
    }

    func testParallelLanesShowOneRunningCardEachAndLaneSummary() {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = LeaseOwner(pid: 1, acquiredAt: now.addingTimeInterval(-300), cwd: "/tmp/ExplorerDex", project: "ExplorerDex", command: ["xcodebuild", "test"], source: .terminal, threadID: nil, threadTitle: nil)
        let second = LeaseOwner(pid: 2, acquiredAt: now.addingTimeInterval(-60), cwd: "/tmp/Set", project: "Set", command: ["xcodebuild", "test"], source: .codex, threadID: nil, threadTitle: "Smoke")
        let status = LeaseStatus(
            state: .leased, owner: first, waiters: [], error: nil, typicalDurations: ["ExplorerDex": 600],
            lanes: [LaneStatus(lane: 0, owner: first, deviceIDs: [], exclusive: false), LaneStatus(lane: 1, owner: second, deviceIDs: [], exclusive: false)],
            laneLimit: 2, gate: LaneGateStatus(open: false, reason: "memory 38% free", memoryFreePercent: 38, cpuIdlePercent: 40)
        )
        let state = MenuDisplayState(status: status, now: now)
        XCTAssertEqual(state.running.map(\.headline), ["ExplorerDex", "Smoke"])
        XCTAssertEqual(state.running.map(\.lane), [0, 1])
        XCTAssertEqual(state.running.first?.typicalSeconds, 600)
        XCTAssertEqual(state.laneSummary, "2 of 2 lanes in use · extra lane closed, memory 38% free")
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
