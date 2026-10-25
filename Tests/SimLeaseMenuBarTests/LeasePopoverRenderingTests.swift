import AppKit
import SwiftUI
import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuBar
@testable import SimLeaseMenuCore

@MainActor
final class LeasePopoverRenderingTests: XCTestCase {
    func testRendersFreeLeasedAndErrorStates() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SimLeasePopoverCaptures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let states: [(name: String, status: LeaseStatus)] = [
            (
                "free",
                LeaseStatus(state: .free, owner: nil, waiters: [], error: nil)
            ),
            (
                "leased",
                leasedStatus
            ),
            (
                "error",
                LeaseStatus(
                    state: .metadataError,
                    owner: nil,
                    waiters: [],
                    error: "Unable to read lease metadata"
                )
            ),
            ("mixed-lane-error", mixedLaneError),
            ("automatic-recovery-before", recoveryStatus(automatic: false)),
            ("automatic-recovery-after", recoveryStatus(automatic: true)),
        ]

        for item in states {
            let model = MenuViewModel(
                provider: RenderStatusProvider(status: item.status)
            )
            await model.setDevicesVisible(true)
            let hosting = NSHostingView(rootView: LeasePopoverView(viewModel: model).background(Color(nsColor: .windowBackgroundColor)))
            hosting.setFrameSize(hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let output = outputDirectory.appending(path: "\(item.name).png")
            try data.write(to: output)

            XCTAssertEqual(hosting.bounds.width, 380, accuracy: 1)
            XCTAssertGreaterThan(hosting.bounds.height, 80)
            XCTAssertLessThanOrEqual(hosting.bounds.height, 820)
            print("popover-capture: \(output.path)")
        }
    }

    private func recoveryStatus(automatic: Bool) -> LeaseStatus {
        let block = CrashLoopTrigger(deviceID: "63B33A57-80CC-4854-81D1-911B3C68E1D5", scopeID: "unowned-system-service", processName: "PosterBoard", signature: "poster", occurredAt: Date())
        let health = automatic ? SimulatorHealthStatus(recoveries: [
            AutomaticRecoveryRecord(deviceID: block.deviceID, state: .history, detail: "Device removed."),
            AutomaticRecoveryRecord(deviceID: "device", state: .verifying, detail: "Checking stable services and new crash reports for 120 booted seconds. App data preserved.")
        ], backgroundIncidentCount: 47, infrastructureBlocks: [block]) : nil
        return LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, crashBlocks: [block], simulatorHealth: health)
    }

    func testWaiterRowsIncreasePopoverHeight() async throws {
        let emptyHeight = try await renderedHeight(waiterNames: [])
        let populatedHeight = try await renderedHeight(
            waiterNames: (1...20).map { "Waiting simulator thread \($0)" }
        )

        XCTAssertGreaterThan(populatedHeight - emptyHeight, 300)
        XCTAssertLessThanOrEqual(populatedHeight, 820)
    }

    private func renderedHeight(waiterNames: [String]) async throws -> CGFloat {
        let status = LeaseStatus(
            state: .leased,
            owner: leasedStatus.owner,
            waiters: waiterNames.enumerated().map { index, name in
                LeaseWaiter(
                    id: "waiter-\(index)",
                    pid: Int32(index + 2),
                    waitingSince: Date(),
                    cwd: "/Users/example/Projects/Project\(index)",
                    project: "Project\(index)",
                    command: ["xcodebuild", "test"],
                    source: .codex,
                    threadID: nil,
                    threadTitle: name
                )
            },
            error: nil
        )
        let model = MenuViewModel(provider: RenderStatusProvider(status: status))
        await model.refresh()
        let renderer = ImageRenderer(content: LeasePopoverView(viewModel: model))
        renderer.proposedSize = ProposedViewSize(width: 320, height: nil)

        return try XCTUnwrap(renderer.nsImage).size.height
    }

    private var leasedStatus: LeaseStatus {
        LeaseStatus(
            state: .leased,
            owner: LeaseOwner(
                pid: 1,
                acquiredAt: Date().addingTimeInterval(-142),
                cwd: "/Users/example/Projects/ExplorerDex",
                project: "ExplorerDex",
                command: [
                    "xcodebuild",
                    "-scheme",
                    "ExplorerDex",
                    "test-without-building",
                ],
                source: .codex,
                threadID: nil,
                threadTitle: "Lens verification"
            ),
            waiters: [
                LeaseWaiter(
                    id: "waiter",
                    pid: 2,
                    waitingSince: Date(),
                    cwd: "/Users/example/Projects/Set",
                    project: "Set",
                    command: ["xcrun", "simctl", "list"],
                    source: .codex,
                    threadID: nil,
                    threadTitle: "Set UI tests",
                    deviceIDs: ["5855AB2E-0078-4A4B-9149-780B23A0AA1C"]
                ),
            ],
            error: nil,
            devices: [
                SimulatorUsage(id: "5855AB2E-0078-4A4B-9149-780B23A0AA1C", name: "iPhone 17 Pro", runtime: "iOS 27.2", state: "Booted", reservation: .owned),
                SimulatorUsage(id: "D61765E6-0EEC-4D07-83EA-4FB7DD535AB0", name: "iPhone 17", runtime: "iOS 27.2", state: "Booted", reservation: .borrowed),
                SimulatorUsage(id: "0BD66E05-B117-43A2-9483-4E2F2011751F", name: "iPhone Air", runtime: "iOS 27.1", state: "Booted", reservation: .unreserved),
            ]
        )
    }

    private var mixedLaneError: LeaseStatus {
        let owner = LeaseOwner(pid: 1, acquiredAt: Date().addingTimeInterval(-300), cwd: "/Projects/ThaiSRS", project: "ThaiSRS", command: ["xcodebuild", "test"], source: .terminal, threadID: nil, threadTitle: "ThaiSRS tests")
        return LeaseStatus(
            state: .metadataError, owner: nil,
            waiters: [LeaseWaiter(id: "queued", pid: 2, waitingSince: Date().addingTimeInterval(-120), cwd: "/Projects/ExplorerDex", project: "ExplorerDex", command: [], source: .codex, threadID: nil, threadTitle: "ExplorerDex screenshots")],
            error: "native work is unresolved",
            lanes: [LaneStatus(lane: 1, owner: owner, deviceIDs: [], exclusive: false)], laneLimit: 3,
            gate: LaneGateStatus(open: false, reason: "CPU recovering", memoryFreePercent: 53, cpuIdlePercent: 50, load: 9, cpus: 10),
            laneErrors: [LaneStatusError(lane: 0, message: "Native work is unresolved. Verify requests, runners and streams have finished before settling the session.", phase: .quarantined)]
        )
    }
}

private actor RenderStatusProvider: MenuStatusProviding {
    let status: LeaseStatus

    init(status: LeaseStatus) {
        self.status = status
    }

    func fetch() async throws -> LeaseStatus {
        status
    }
}
