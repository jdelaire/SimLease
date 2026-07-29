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
        ]

        for item in states {
            let model = MenuViewModel(
                provider: RenderStatusProvider(status: item.status)
            )
            await model.refresh()
            let renderer = ImageRenderer(
                content: LeasePopoverView(viewModel: model)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
            renderer.proposedSize = ProposedViewSize(width: 320, height: nil)
            renderer.scale = 2

            let image = try XCTUnwrap(renderer.nsImage)
            let data = try XCTUnwrap(
                NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                    .representation(using: .png, properties: [:])
            )
            let output = outputDirectory.appending(path: "\(item.name).png")
            try data.write(to: output)

            XCTAssertEqual(image.size.width, 320, accuracy: 1)
            XCTAssertGreaterThan(image.size.height, 80)
            XCTAssertLessThan(image.size.height, 400)
            print("popover-capture: \(output.path)")
        }
    }

    func testWaiterRowsIncreasePopoverHeight() async throws {
        let emptyHeight = try await renderedHeight(waiterNames: [])
        let populatedHeight = try await renderedHeight(
            waiterNames: (1...20).map { "Waiting simulator thread \($0)" }
        )

        XCTAssertGreaterThanOrEqual(populatedHeight - emptyHeight, 650)
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
                    threadTitle: "Set UI tests"
                ),
            ],
            error: nil
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
