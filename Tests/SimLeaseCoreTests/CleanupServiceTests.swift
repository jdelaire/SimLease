import Foundation
import XCTest
@testable import SimLeaseCore

final class CleanupServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    func testBusyLeaseDefersSimulatorButStillReturnsStorageReview() throws {
        let fixture = try ServiceFixture(now: now)
        defer { fixture.stopHolder() }
        try fixture.startHolder()
        try fixture.metadata.writeOwner(fixture.owner)
        fixture.storageProvider.inventoryValue = XcodeStorageInventory(
            targets: [fixture.storageTarget()],
            protected: []
        )

        let review = try fixture.service().createPlan()

        XCTAssertEqual(review.plan?.storage.map(\.identifier), ["storage"])
        XCTAssertEqual(
            review.deferred,
            [.simulatorDevice, .simulatorRuntime, .simulatorDeviceData]
        )
        XCTAssertEqual(fixture.provider.inventoryCallCount, 0)
        XCTAssertEqual(fixture.storageProvider.inventoryCallCount, 1)
    }

    func testDeviceDataSelectionWaitsForBusyLease() throws {
        let fixture = try ServiceFixture(now: now)
        defer { fixture.stopHolder() }
        let target = CleanupTarget(kind: .deviceData, identifier: "device-data:DEVICE-1", name: "Device caches & logs", category: .simulatorDeviceData, path: "/Devices/DEVICE-1/data", runtimeIdentifier: "runtime.current", lastUsedAt: nil, sizeBytes: 100, fingerprint: .deviceData(path: "/Devices/DEVICE-1/data", digest: "d"))
        try fixture.store.save(CleanupPlan(id: "ABC123", createdAt: now, expiresAt: now.addingTimeInterval(600), devices: [], runtimes: [], storage: [target], protected: [], estimatedBytes: 100, availableBytesBefore: nil))
        try fixture.startHolder()
        try fixture.metadata.writeOwner(fixture.owner)

        let result = try fixture.service().apply(planID: "ABC123", selectedTargetIDs: [target.identifier])

        XCTAssertEqual(result.items.map(\.message), ["Simulator lease is in use"])
        XCTAssertEqual(fixture.provider.inventoryCallCount, 0)
    }

    func testEmptyReviewIsReturnedWithoutSaving() throws {
        let fixture = try ServiceFixture(now: now)
        fixture.provider.inventories = [.success(fixture.emptyInventory())]

        let review = try fixture.service().createPlan()

        XCTAssertNil(review.plan)
        XCTAssertThrowsError(
            try fixture.store.consume(id: "ABC123", now: now)
        ) {
            XCTAssertEqual($0 as? CleanupPlanStoreError, .missing)
        }
    }

    func testCollisionRetriesAndSavesNonemptyPlan() throws {
        let fixture = try ServiceFixture(now: now)
        try fixture.store.save(fixture.plan(id: "ABC123"))
        fixture.provider.inventories = [.success(fixture.deviceInventory())]
        let ids = IDSequence(["ABC123", "DEF456"])

        let review = try fixture.service(idGenerator: ids.next).createPlan()

        XCTAssertEqual(review.plan?.id, "DEF456")
        XCTAssertEqual(
            try fixture.store.consume(id: "DEF456", now: now).id,
            "DEF456"
        )
    }

    func testApplyConsumesBeforeExecutorErrorAndReleasesLease() throws {
        let fixture = try ServiceFixture(now: now)
        try fixture.store.save(fixture.plan(id: "ABC123"))
        fixture.provider.inventories = [.failure(
            CleanupInventoryError.invalidDevicesJSON
        )]

        XCTAssertThrowsError(
            try fixture.service().apply(planID: "ABC123")
        ) {
            XCTAssertEqual(
                $0 as? CleanupServiceError,
                .inventory(.invalidDevicesJSON)
            )
        }
        XCTAssertThrowsError(
            try fixture.store.consume(id: "ABC123", now: now)
        ) {
            XCTAssertEqual($0 as? CleanupPlanStoreError, .missing)
        }
        let handle = try XCTUnwrap(
            fixture.coordinator.tryAcquire(identity: fixture.identity)
        )
        handle.release()
    }

    func testExpiredPlanMapsWithoutInvokingExecutorAndReleasesLease() throws {
        let fixture = try ServiceFixture(now: now)
        try fixture.store.save(fixture.plan(
            id: "ABC123",
            expiresAt: now.addingTimeInterval(-1)
        ))

        XCTAssertThrowsError(
            try fixture.service().apply(planID: "ABC123")
        ) {
            XCTAssertEqual(
                $0 as? CleanupServiceError,
                .plan(.expired)
            )
        }
        XCTAssertEqual(fixture.provider.inventoryCallCount, 0)
        let handle = try XCTUnwrap(
            fixture.coordinator.tryAcquire(identity: fixture.identity)
        )
        handle.release()
    }
}

private final class ServiceFixture {
    let paths: LeasePaths
    let metadata: MetadataStore
    let coordinator: LeaseCoordinator
    let store: CleanupPlanStore
    let provider = ServiceCleanupProvider()
    let storageProvider = ServiceStorageProvider()
    let fileOperator = ServiceFileOperator()
    let identity: LeaseIdentity
    let owner: LeaseOwner
    let now: Date
    private var holder: Process?

    init(now: Date) throws {
        self.now = now
        paths = LeasePaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        metadata = try MetadataStore(paths: paths)
        coordinator = LeaseCoordinator(paths: paths, store: metadata)
        store = try CleanupPlanStore(paths: paths)
        identity = LeaseIdentity(
            pid: 50,
            cwd: "/Projects/SimLease",
            project: "SimLease",
            command: ["simlease", "clean", "plan"],
            source: .terminal,
            threadID: nil,
            threadTitle: nil
        )
        owner = LeaseOwner(
            pid: 40,
            acquiredAt: now,
            cwd: "/Projects/Other",
            project: "Other",
            command: ["xcodebuild", "test"],
            source: .terminal,
            threadID: nil,
            threadTitle: nil
        )
    }

    deinit {
        stopHolder()
        try? FileManager.default.removeItem(at: paths.root)
    }

    func service(
        idGenerator: @escaping @Sendable () -> String = { "ABC123" }
    ) -> CleanupService {
        let planner = CleanupPlanner(
            devicesRoot: URL(fileURLWithPath: "/Devices")
        )
        return CleanupService(
            coordinator: coordinator,
            identity: identity,
            provider: provider,
            planner: planner,
            store: store,
            executor: CleanupExecutor(
                provider: provider,
                planner: planner,
                storageProvider: storageProvider,
                fileOperator: fileOperator
            ),
            storageProvider: storageProvider,
            now: { [now] in now },
            idGenerator: idGenerator
        )
    }

    func storageTarget() -> CleanupTarget {
        CleanupTarget(
            kind: .filesystem,
            identifier: "storage",
            name: "Storage",
            detail: "/allowed/storage",
            category: .derivedData,
            riskTier: .rebuildable,
            action: .deletePermanently,
            path: "/allowed/storage",
            runtimeIdentifier: "",
            lastUsedAt: now.addingTimeInterval(-15 * 86_400),
            sizeBytes: 100,
            fingerprint: .filesystem(
                path: "/allowed/storage",
                sizeBytes: 100,
                modifiedAt: now.addingTimeInterval(-15 * 86_400)
            ),
            selectedByDefault: true
        )
    }

    func emptyInventory() -> CleanupInventory {
        CleanupInventory(
            devices: [],
            runtimes: [],
            outdatedRuntimeIDs: [],
            hasActiveXcodeTests: false,
            availableBytes: 100
        )
    }

    func deviceInventory() -> CleanupInventory {
        CleanupInventory(
            devices: [
                CleanupDeviceRecord(
                    identifier: "DEVICE-1",
                    name: "Device",
                    runtimeIdentifier: "runtime.current",
                    state: "Shutdown",
                    lastUsedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
                    dataPath: "/Devices/DEVICE-1/data",
                    sizeBytes: 100
                ),
            ],
            runtimes: [],
            outdatedRuntimeIDs: [],
            hasActiveXcodeTests: false,
            availableBytes: 100
        )
    }

    func plan(
        id: String,
        expiresAt: Date? = nil
    ) -> CleanupPlan {
        CleanupPlan(
            id: id,
            createdAt: now.addingTimeInterval(-60),
            expiresAt: expiresAt ?? now.addingTimeInterval(600),
            devices: [
                CleanupTarget(
                    kind: .device,
                    identifier: "DEVICE-1",
                    name: "Device",
                    runtimeIdentifier: "runtime.current",
                    lastUsedAt: now.addingTimeInterval(-31 * 86_400),
                    sizeBytes: 100
                ),
            ],
            runtimes: [],
            protected: [],
            estimatedBytes: 0,
            availableBytesBefore: 100
        )
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

private final class ServiceStorageProvider:
    XcodeStorageInventoryProviding,
    @unchecked Sendable
{
    var inventoryValue = XcodeStorageInventory(targets: [], protected: [])
    private(set) var inventoryCallCount = 0

    func inventory(now: Date) throws -> XcodeStorageInventory {
        inventoryCallCount += 1
        return inventoryValue
    }
}

private struct ServiceFileOperator: CleanupFileOperating {
    func delete(_ url: URL) throws {}
    func trash(_ url: URL) throws {}
}

private final class ServiceCleanupProvider:
    CleanupInventoryProviding,
    @unchecked Sendable
{
    var inventories: [Result<CleanupInventory, Error>] = []
    private(set) var inventoryCallCount = 0

    func inventory() throws -> CleanupInventory {
        inventoryCallCount += 1
        guard !inventories.isEmpty else {
            throw CleanupInventoryError.invalidDevicesJSON
        }
        return try inventories.removeFirst().get()
    }

    func deleteDevice(id: String) throws {}
    func deleteRuntime(id: String) throws {}
}

private final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.withLock { values.removeFirst() }
    }
}
