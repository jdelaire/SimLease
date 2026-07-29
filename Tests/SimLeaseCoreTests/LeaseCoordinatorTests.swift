import Foundation
import XCTest
@testable import SimLeaseCore

final class LeaseCoordinatorTests: XCTestCase {
    func testTryAcquireReturnsNilWithoutCreatingWaiterWhenBusy() throws {
        let fixture = try ProcessLeaseFixture()
        defer { fixture.stopHolder() }
        try fixture.startHolder()

        let handle = try fixture.coordinator.tryAcquire(identity: fixture.identity)

        XCTAssertNil(handle)
        XCTAssertEqual(try fixture.store.readWaiters(), [])
    }

    func testTryAcquireWritesOwnerAndReturnsHandleWhenFree() throws {
        let fixture = try ProcessLeaseFixture()

        let handle = try XCTUnwrap(
            fixture.coordinator.tryAcquire(identity: fixture.identity)
        )

        let storedOwner = try XCTUnwrap(fixture.store.readOwner())
        XCTAssertEqual(storedOwner.pid, handle.owner.pid)
        XCTAssertEqual(storedOwner.command, handle.owner.command)
        XCTAssertEqual(storedOwner.threadID, handle.owner.threadID)
        handle.release()
        XCTAssertEqual(try fixture.coordinator.status().state, .free)
    }

    func testSecondProcessCannotAcquireWhileFirstHoldsLock() throws {
        let fixture = try ProcessLeaseFixture()
        defer { fixture.stopHolder() }
        try fixture.startHolder()

        XCTAssertThrowsError(try fixture.coordinator.acquire(identity: fixture.identity)) {
            XCTAssertEqual($0 as? LeaseAcquisitionError, .timedOut)
        }
        XCTAssertEqual(try fixture.store.readWaiters(), [])
    }

    func testLockBecomesAvailableAfterHolderExits() throws {
        let fixture = try ProcessLeaseFixture()
        try fixture.startHolder()
        fixture.stopHolder()

        let handle = try fixture.coordinator.acquire(identity: fixture.identity)
        handle.release()

        XCTAssertEqual(try fixture.coordinator.status().state, .free)
    }

    func testWaitReporterReceivesCurrentOwner() throws {
        let fixture = try ProcessLeaseFixture(reportInterval: .milliseconds(20))
        defer { fixture.stopHolder() }
        try fixture.store.writeOwner(fixture.owner)
        try fixture.startHolder()
        let reports = SendableBox<[LeaseStatus]>([])

        XCTAssertThrowsError(
            try fixture.coordinator.acquire(
                identity: fixture.identity,
                onWaitReport: { status in reports.withValue { $0.append(status) } }
            )
        )

        XCTAssertEqual(reports.value.last?.state, .leased)
        XCTAssertEqual(reports.value.last?.owner, fixture.owner)
    }

    func testStatusDistinguishesFreeLeasedAndMissingMetadata() throws {
        let fixture = try ProcessLeaseFixture()
        XCTAssertEqual(try fixture.coordinator.status().state, .free)

        try fixture.store.writeOwner(fixture.owner)
        try fixture.startHolder()
        XCTAssertEqual(try fixture.coordinator.status().state, .leased)

        try fixture.store.removeOwner()
        let missing = try fixture.coordinator.status()
        XCTAssertEqual(missing.state, .metadataError)
        XCTAssertEqual(missing.error, "owner metadata missing while lease is held")
        fixture.stopHolder()
    }

    func testCorruptOwnerWhileHeldReportsMetadataError() throws {
        let fixture = try ProcessLeaseFixture()
        try Data("bad-json".utf8).write(to: fixture.paths.owner)
        try fixture.startHolder()
        defer { fixture.stopHolder() }

        let status = try fixture.coordinator.status()

        XCTAssertEqual(status.state, .metadataError)
        XCTAssertNotNil(status.error)
    }

    func testStatusPrunesStaleWaiters() throws {
        let inspector = StubProcessIdentityInspector(
            states: [
                101: .matching,
                102: .missing,
                103: .reused,
                104: .unknown,
            ]
        )
        let fixture = try ProcessLeaseFixture(processInspector: inspector)
        let waitingSince = Date(timeIntervalSince1970: 100)
        let waiters = (101...104).map { pid in
            LeaseWaiter(
                id: "\(pid)-waiter",
                pid: Int32(pid),
                waitingSince: waitingSince,
                cwd: "/Projects/SimLease",
                project: "SimLease",
                command: ["xcrun", "simctl", "list"],
                source: .codex,
                threadID: "thread-\(pid)",
                threadTitle: nil
            )
        }
        for waiter in waiters {
            try fixture.store.writeWaiter(waiter)
        }

        let status = try fixture.coordinator.status()

        XCTAssertEqual(
            status.waiters.map(\.id),
            ["101-waiter", "104-waiter"]
        )
        XCTAssertEqual(
            try fixture.store.readWaiters().map(\.id),
            ["101-waiter", "104-waiter"]
        )
    }
}

private final class ProcessLeaseFixture {
    let paths: LeasePaths
    let store: MetadataStore
    let coordinator: LeaseCoordinator
    let identity: LeaseIdentity
    let owner: LeaseOwner
    private var holder: Process?

    init(
        reportInterval: Duration = .milliseconds(50),
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector()
    ) throws {
        paths = LeasePaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        store = try MetadataStore(paths: paths)
        coordinator = LeaseCoordinator(
            paths: paths,
            store: store,
            timing: LeaseTiming(
                timeout: .milliseconds(120),
                reportInterval: reportInterval,
                pollInterval: .milliseconds(10)
            ),
            processInspector: processInspector
        )
        identity = LeaseIdentity(
            pid: 52,
            cwd: "/Projects/Set",
            project: "Set",
            command: ["xcrun", "simctl", "list"],
            source: .codex,
            threadID: "019faaef",
            threadTitle: nil
        )
        owner = LeaseOwner(
            pid: 41,
            acquiredAt: Date(
                timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 10
            ),
            cwd: "/Projects/SimLease",
            project: "SimLease",
            command: ["xcodebuild", "test"],
            source: .codex,
            threadID: "owner-thread",
            threadTitle: "[SimLease] Owner"
        )
    }

    deinit {
        stopHolder()
        try? FileManager.default.removeItem(at: paths.root)
    }

    func startHolder() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [paths.lock.path, "/bin/sleep", "5"]
        try process.run()
        holder = process

        let deadline = Date(timeIntervalSinceNow: 1)
        while Date() < deadline {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            probe.arguments = ["-t", "0", paths.lock.path, "/usr/bin/true"]
            probe.standardError = Pipe()
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus != 0 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("holder did not acquire lock")
    }

    func stopHolder() {
        guard let holder else { return }
        if holder.isRunning {
            holder.terminate()
            holder.waitUntilExit()
        }
        self.holder = nil
    }
}

private struct StubProcessIdentityInspector: ProcessIdentityInspecting {
    let states: [Int32: ProcessIdentityState]

    func identityState(
        pid: Int32,
        waitingSince: Date
    ) -> ProcessIdentityState {
        states[pid] ?? .unknown
    }
}

private final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }
}
