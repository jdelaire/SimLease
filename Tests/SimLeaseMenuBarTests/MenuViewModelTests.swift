import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuCore

@MainActor
final class MenuViewModelTests: XCTestCase {
    func testUnmanagedActivityIsVisibleWhileLaneRemainsFree() async {
        let activity = SimulatorActivityReport(activities: [SimulatorActivity(
            process: ProcessReference(pid: 99, startMicroseconds: 100), tool: "simctl", kind: .unmanaged, deviceIDs: []
        )])
        let provider = SequenceStatusStub(statuses: [
            LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, activity: activity),
            LeaseStatus(state: .free, owner: nil, waiters: [], error: nil, activity: SimulatorActivityReport()),
        ])
        let model = MenuViewModel(provider: provider)
        await model.refresh()
        XCTAssertEqual(model.state.kind, .free)
        XCTAssertEqual(model.state.menuTitle, "Simulator · Unmanaged")
        XCTAssertTrue(model.copyDetailsText.contains("simctl PID 99"))
        await model.refresh()
        XCTAssertEqual(model.state.menuTitle, "Simulator · Free")
    }

    func testIncompleteAuditCannotDisplayUnqualifiedFreeStatus() async {
        let model = MenuViewModel(provider: StatusStub(status: LeaseStatus(
            state: .free, owner: nil, waiters: [], error: nil,
            activity: SimulatorActivityReport(uninspectedProcessCount: 1)
        )))
        await model.refresh()
        XCTAssertEqual(model.state.menuTitle, "Simulator · Audit incomplete")
    }

    func testRefreshPublishesLeasedState() async {
        let model = MenuViewModel(
            provider: StatusStub(status: leasedStatus(waiters: [waiter(title: "Waiting task")])),
            now: { Date(timeIntervalSince1970: 502) }
        )

        await model.refresh()

        XCTAssertEqual(model.state.kind, .leased)
        XCTAssertEqual(model.state.ownerName, "Owner task")
        XCTAssertEqual(model.state.waiters.map(\.name), ["Waiting task"])
    }

    func testProviderErrorPublishesExactMessage() async {
        let model = MenuViewModel(provider: ErrorStub())

        await model.refresh()

        XCTAssertEqual(model.state, .metadataError("status exploded"))
    }

    func testCopyDetailsContainsVisibleLeaseDetails() async {
        let model = MenuViewModel(
            provider: StatusStub(status: leasedStatus(waiters: [waiter(title: "Waiting task")])),
            now: { Date(timeIntervalSince1970: 502) }
        )
        await model.refresh()

        XCTAssertTrue(model.copyDetailsText.contains("Owner task"))
        XCTAssertTrue(model.copyDetailsText.contains("SimLease · Codex"))
        XCTAssertTrue(model.copyDetailsText.contains("xcodebuild test"))
        XCTAssertTrue(model.copyDetailsText.contains("06:42"))
        XCTAssertTrue(model.copyDetailsText.contains("Waiting task"))
        XCTAssertTrue(model.copyDetailsText.contains("Set · Codex · 00:00"))
        XCTAssertTrue(model.copyDetailsText.contains("xcrun simctl list"))
        XCTAssertTrue(model.copyDetailsText.contains("Thread: 019fbb00-c552-7933"))
        XCTAssertTrue(model.copyDetailsText.contains("Path: /tmp/Set"))
    }

    func testRepeatedRefreshReplacesWaiters() async {
        let provider = SequenceStatusStub(statuses: [
            leasedStatus(waiters: [waiter(title: "First")]),
            leasedStatus(waiters: [waiter(title: "Second")]),
        ])
        let model = MenuViewModel(provider: provider)

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(model.state.waiters.map(\.name), ["Second"])
    }

    func testCLIProviderRunsOnlyStatusJSON() async throws {
        let fixture = try executableFixture(
            body: """
            [[ "$#" == 3 && "$1" == status && "$2" == --json && "$3" == --audit ]] || exit 9
            /bin/cat "$0.json"
            """,
            status: LeaseStatus(state: .free, owner: nil, waiters: [], error: nil)
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = CLIStatusProvider(
            environment: ["SIMLEASE_EXECUTABLE_PATH": fixture.executable.path]
        )

        let status = try await provider.fetch()

        XCTAssertEqual(status.state, .free)
    }

    func testCLIProviderReportsCommandFailure() async throws {
        let fixture = try executableFixture(body: "print -u2 -- unavailable; exit 12")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = CLIStatusProvider(
            environment: ["SIMLEASE_EXECUTABLE_PATH": fixture.executable.path]
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expected command failure")
        } catch let error as MenuStatusError {
            XCTAssertEqual(error, .commandFailed(code: 12, stderr: "unavailable\n"))
        }
    }

    func testCLIProviderRejectsInvalidJSON() async throws {
        let fixture = try executableFixture(body: "print -- not-json")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = CLIStatusProvider(
            environment: ["SIMLEASE_EXECUTABLE_PATH": fixture.executable.path]
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expected invalid JSON")
        } catch let error as MenuStatusError {
            XCTAssertEqual(error, .invalidJSON)
        }
    }

    func testCLIProviderDrainsLargeOutputAndErrorStreams() async throws {
        let fixture = try executableFixture(body: """
            /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\0' ' '
            /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\0' ' ' >&2
            /bin/cat "$0.json"
            """, status: LeaseStatus(state: .free, owner: nil, waiters: [], error: nil))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = CLIStatusProvider(environment: ["SIMLEASE_EXECUTABLE_PATH": fixture.executable.path])
        let status = try await provider.fetch()
        XCTAssertEqual(status.state, .free)
    }

    private func executableFixture(
        body: String,
        status: LeaseStatus? = nil
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let executable = directory.appending(path: "simlease")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/zsh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        if let status {
            try JSONEncoder.simLease.encode(status).write(
                to: URL(fileURLWithPath: executable.path + ".json")
            )
        }
        return (directory, executable)
    }

    private func leasedStatus(waiters: [LeaseWaiter]) -> LeaseStatus {
        LeaseStatus(
            state: .leased,
            owner: LeaseOwner(
                pid: 1,
                acquiredAt: Date(timeIntervalSince1970: 100),
                cwd: "/tmp/SimLease",
                project: "SimLease",
                command: ["xcodebuild", "test"],
                source: .codex,
                threadID: "019faaef-c552-7933",
                threadTitle: "Owner task"
            ),
            waiters: waiters,
            error: nil
        )
    }

    private func waiter(title: String) -> LeaseWaiter {
        LeaseWaiter(
            id: title,
            pid: 2,
            waitingSince: Date(),
            cwd: "/tmp/Set",
            project: "Set",
            command: ["xcrun", "simctl", "list"],
            source: .codex,
            threadID: "019fbb00-c552-7933",
            threadTitle: title
        )
    }
}

private actor StatusStub: MenuStatusProviding {
    let status: LeaseStatus

    init(status: LeaseStatus) {
        self.status = status
    }

    func fetch() async throws -> LeaseStatus { status }
}

private actor SequenceStatusStub: MenuStatusProviding {
    private var statuses: [LeaseStatus]

    init(statuses: [LeaseStatus]) {
        self.statuses = statuses
    }

    func fetch() async throws -> LeaseStatus {
        statuses.removeFirst()
    }
}

private struct ErrorStub: MenuStatusProviding {
    func fetch() async throws -> LeaseStatus {
        throw TestStatusError()
    }
}

private struct TestStatusError: LocalizedError {
    var errorDescription: String? { "status exploded" }
}
