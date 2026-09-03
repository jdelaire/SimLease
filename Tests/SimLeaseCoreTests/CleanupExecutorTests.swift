import Foundation
import XCTest
@testable import SimLeaseCore

final class CleanupExecutorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    func testRevalidatesInOrderAndMeasuresFirstAndLastCapacity() throws {
        let plan = makePlan(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"])
        let provider = SequenceCleanupProvider(
            inventories: [
                .success(inventory(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"], available: 100)),
                .success(inventory(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"], available: 110)),
                .success(inventory(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"], available: 120)),
                .success(inventory(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"], available: 130)),
                .success(inventory(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"], available: 140)),
                .success(inventory(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"], available: 900)),
            ]
        )

        let result = try executor(provider).apply(plan: plan, now: now)

        XCTAssertEqual(provider.calls, [
            .inventory,
            .inventory,
            .deleteDevice("DEVICE-1"),
            .inventory,
            .deleteDevice("DEVICE-2"),
            .inventory,
            .inventory,
            .deleteRuntime("RUNTIME-1"),
            .inventory,
        ])
        XCTAssertEqual(result.availableBytesBefore, 100)
        XCTAssertEqual(result.availableBytesAfter, 900)
        XCTAssertFalse(result.isPartial)
    }

    func testDeviceDriftSkipsAndNewCandidatesAreIgnored() throws {
        let plan = makePlan(deviceIDs: ["DEVICE-1"])
        let provider = SequenceCleanupProvider(inventories: [
            .success(inventory(deviceIDs: ["DEVICE-1"])),
            .success(inventory(
                deviceIDs: ["DEVICE-1", "NEW"],
                bootedDeviceIDs: ["DEVICE-1"]
            )),
            .success(inventory(deviceIDs: ["NEW"])),
        ])

        let result = try executor(provider).apply(plan: plan, now: now)

        XCTAssertEqual(result.items.map(\.outcome), [.skipped])
        XCTAssertFalse(provider.calls.contains(.deleteDevice("DEVICE-1")))
        XCTAssertFalse(provider.calls.contains(.deleteDevice("NEW")))
        XCTAssertTrue(result.isPartial)
    }

    func testMissingDeviceAndRuntimeSafetyDriftAreSkipped() throws {
        let plan = makePlan(deviceIDs: ["MISSING"], runtimeIDs: ["RUNTIME-1"])
        let provider = SequenceCleanupProvider(inventories: [
            .success(inventory(deviceIDs: ["MISSING"], runtimeIDs: ["RUNTIME-1"])),
            .success(inventory(runtimeIDs: ["RUNTIME-1"])),
            .success(inventory(runtimeIDs: ["RUNTIME-1"], outdatedRuntimeIDs: [])),
            .success(inventory(runtimeIDs: ["RUNTIME-1"], outdatedRuntimeIDs: [])),
        ])

        let result = try executor(provider).apply(plan: plan, now: now)

        XCTAssertEqual(result.items.map(\.outcome), [.skipped, .skipped])
        XCTAssertFalse(provider.calls.contains(.deleteRuntime("RUNTIME-1")))
    }

    func testActiveTestsSkipEveryRemainingTarget() throws {
        let plan = makePlan(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"])
        let provider = SequenceCleanupProvider(inventories: [
            .success(inventory(deviceIDs: ["DEVICE-1", "DEVICE-2"], runtimeIDs: ["RUNTIME-1"])),
            .success(inventory(
                deviceIDs: ["DEVICE-1", "DEVICE-2"],
                runtimeIDs: ["RUNTIME-1"],
                hasActiveTests: true
            )),
            .success(inventory(hasActiveTests: true)),
        ])

        let result = try executor(provider).apply(plan: plan, now: now)

        XCTAssertEqual(result.items.map(\.outcome), [.skipped, .skipped, .skipped])
        XCTAssertFalse(provider.calls.contains { call in
            if case .inventory = call { return false }
            return true
        })
    }

    func testInvalidDeviceDeleteRefreshesAndBecomesSkipped() throws {
        let provider = SequenceCleanupProvider(
            inventories: [
                .success(inventory(deviceIDs: ["DEVICE-1"])),
                .success(inventory(deviceIDs: ["DEVICE-1"])),
                .success(inventory()),
                .success(inventory(available: 800)),
            ],
            deviceDeleteErrors: [
                "DEVICE-1": CleanupInventoryError.commandFailed(
                    arguments: [],
                    code: 148,
                    stderr: "Invalid device: DEVICE-1"
                ),
            ]
        )

        let result = try executor(provider).apply(
            plan: makePlan(deviceIDs: ["DEVICE-1"]),
            now: now
        )

        XCTAssertEqual(result.items.first?.outcome, .skipped)
        XCTAssertEqual(provider.calls, [
            .inventory,
            .inventory,
            .deleteDevice("DEVICE-1"),
            .inventory,
            .inventory,
        ])
    }

    func testOtherDeleteErrorFailsAndRuntimeInventoryFailureSkipsRuntime() throws {
        let provider = SequenceCleanupProvider(
            inventories: [
                .success(inventory(deviceIDs: ["DEVICE-1"], runtimeIDs: ["RUNTIME-1"])),
                .success(inventory(deviceIDs: ["DEVICE-1"], runtimeIDs: ["RUNTIME-1"])),
                .failure(TestError.inventory),
                .success(inventory(available: 700)),
            ],
            deviceDeleteErrors: ["DEVICE-1": TestError.delete]
        )

        let result = try executor(provider).apply(
            plan: makePlan(deviceIDs: ["DEVICE-1"], runtimeIDs: ["RUNTIME-1"]),
            now: now
        )

        XCTAssertEqual(result.items.map(\.outcome), [.failed, .skipped])
        XCTAssertTrue(result.isPartial)
    }

    func testFilesystemApplyUsesExactSelectionAndAction() throws {
        let deleted = storageTarget(
            id: "derived",
            path: "/allowed/derived",
            action: .deletePermanently
        )
        let trashed = storageTarget(
            id: "archive",
            path: "/allowed/archive",
            action: .moveToTrash
        )
        let plan = CleanupPlan(
            id: "ABC123",
            createdAt: now,
            expiresAt: now.addingTimeInterval(600),
            devices: [],
            runtimes: [],
            storage: [deleted, trashed],
            protected: [],
            estimatedBytes: 200,
            availableBytesBefore: nil
        )
        let storage = SequenceStorageProvider(
            inventories: [
                XcodeStorageInventory(
                    targets: [deleted, trashed],
                    protected: []
                ),
            ]
        )
        let files = RecordingFileOperator()
        let executor = CleanupExecutor(
            provider: SequenceCleanupProvider(inventories: []),
            planner: CleanupPlanner(
                devicesRoot: URL(fileURLWithPath: "/Devices")
            ),
            storageProvider: storage,
            fileOperator: files
        )

        let result = try executor.apply(
            plan: plan,
            selectedTargetIDs: ["archive"],
            now: now
        )

        XCTAssertEqual(files.calls, [.trash("/allowed/archive")])
        XCTAssertEqual(result.items.map(\.outcome), [.movedToTrash])
    }

    func testChangedFilesystemFingerprintIsSkipped() throws {
        let planned = storageTarget(
            id: "derived",
            path: "/allowed/derived",
            action: .deletePermanently
        )
        let changed = CleanupTarget(
            kind: .filesystem,
            identifier: planned.identifier,
            name: planned.name,
            detail: planned.detail,
            category: planned.category,
            riskTier: planned.riskTier,
            action: planned.action,
            path: planned.path,
            runtimeIdentifier: "",
            lastUsedAt: planned.lastUsedAt,
            sizeBytes: 999,
            fingerprint: .filesystem(
                path: "/allowed/derived",
                sizeBytes: 999,
                modifiedAt: now
            ),
            selectedByDefault: true
        )
        let storage = SequenceStorageProvider(
            inventories: [
                XcodeStorageInventory(targets: [changed], protected: []),
            ]
        )
        let files = RecordingFileOperator()
        let executor = CleanupExecutor(
            provider: SequenceCleanupProvider(inventories: []),
            planner: CleanupPlanner(
                devicesRoot: URL(fileURLWithPath: "/Devices")
            ),
            storageProvider: storage,
            fileOperator: files
        )
        let plan = CleanupPlan(
            id: "ABC123",
            createdAt: now,
            expiresAt: now.addingTimeInterval(600),
            devices: [],
            runtimes: [],
            storage: [planned],
            protected: [],
            estimatedBytes: 100,
            availableBytesBefore: nil
        )

        let result = try executor.apply(
            plan: plan,
            selectedTargetIDs: ["derived"],
            now: now
        )

        XCTAssertEqual(result.items.map(\.outcome), [.skipped])
        XCTAssertTrue(files.calls.isEmpty)
    }

    func testNewlyReservedLaneDeviceSkippedAtApply() throws {
        let provider = SequenceCleanupProvider(inventories: [
            .success(inventory(deviceIDs: ["DEVICE-1"])),
        ])
        let executor = CleanupExecutor(
            provider: provider,
            planner: CleanupPlanner(
                devicesRoot: URL(fileURLWithPath: "/Devices")
            ),
            laneProtectionProvider: {
                LaneProtectionSnapshot(
                    reservedDeviceIDs: ["DEVICE-1"],
                    activeDerivedDataPaths: [],
                    activeResultBundlePaths: []
                )
            }
        )

        let result = try executor.apply(
            plan: makePlan(deviceIDs: ["DEVICE-1"]),
            now: now
        )

        XCTAssertEqual(result.items.map(\.outcome), [.skipped])
        XCTAssertEqual(
            result.items.first?.message,
            "Reserved by a managed simulator lane since review"
        )
        XCTAssertFalse(provider.calls.contains(.deleteDevice("DEVICE-1")))
    }

    func testLaneProtectionFailureSkipsEveryTarget() throws {
        let provider = SequenceCleanupProvider(inventories: [
            .success(inventory(deviceIDs: ["DEVICE-1"])),
        ])
        let executor = CleanupExecutor(
            provider: provider,
            planner: CleanupPlanner(
                devicesRoot: URL(fileURLWithPath: "/Devices")
            ),
            laneProtectionProvider: { throw TestError.inventory }
        )

        let result = try executor.apply(
            plan: makePlan(deviceIDs: ["DEVICE-1"]),
            now: now
        )

        XCTAssertEqual(result.items.map(\.outcome), [.skipped])
        XCTAssertEqual(
            result.items.first?.message,
            "Lane protection revalidation failed"
        )
        XCTAssertFalse(provider.calls.contains(.deleteDevice("DEVICE-1")))
    }

    func testLaneActiveStoragePathSkippedAtApply() throws {
        let planned = storageTarget(
            id: "derived",
            path: "/Lanes/Proj/lane-1",
            action: .deletePermanently
        )
        let storage = SequenceStorageProvider(
            inventories: [
                XcodeStorageInventory(targets: [planned], protected: []),
            ]
        )
        let files = RecordingFileOperator()
        let executor = CleanupExecutor(
            provider: SequenceCleanupProvider(inventories: []),
            planner: CleanupPlanner(
                devicesRoot: URL(fileURLWithPath: "/Devices")
            ),
            storageProvider: storage,
            fileOperator: files,
            laneProtectionProvider: {
                LaneProtectionSnapshot(
                    reservedDeviceIDs: [],
                    activeDerivedDataPaths: ["/Lanes/Proj/lane-1"],
                    activeResultBundlePaths: []
                )
            }
        )
        let plan = CleanupPlan(
            id: "ABC123",
            createdAt: now,
            expiresAt: now.addingTimeInterval(600),
            devices: [],
            runtimes: [],
            storage: [planned],
            protected: [],
            estimatedBytes: 100,
            availableBytesBefore: nil
        )

        let result = try executor.apply(
            plan: plan,
            selectedTargetIDs: ["derived"],
            now: now
        )

        XCTAssertEqual(result.items.map(\.outcome), [.skipped])
        XCTAssertEqual(
            result.items.first?.message,
            "A managed simulator lane uses this path"
        )
        XCTAssertTrue(files.calls.isEmpty)
    }

    private func executor(_ provider: SequenceCleanupProvider) -> CleanupExecutor {
        CleanupExecutor(
            provider: provider,
            planner: CleanupPlanner(
                devicesRoot: URL(fileURLWithPath: "/Devices")
            )
        )
    }

    private func makePlan(
        deviceIDs: [String] = [],
        runtimeIDs: [String] = []
    ) -> CleanupPlan {
        CleanupPlan(
            id: "ABC123",
            createdAt: now,
            expiresAt: now.addingTimeInterval(600),
            devices: deviceIDs.map { target(.device, $0) },
            runtimes: runtimeIDs.map { target(.runtime, $0) },
            protected: [],
            estimatedBytes: 300,
            availableBytesBefore: 100
        )
    }

    private func target(_ kind: CleanupTargetKind, _ id: String) -> CleanupTarget {
        CleanupTarget(
            kind: kind,
            identifier: id,
            name: id,
            runtimeIdentifier: kind == .device ? "runtime.current" : "runtime.\(id)",
            lastUsedAt: kind == .device
                ? now.addingTimeInterval(-31 * 24 * 60 * 60)
                : nil,
            sizeBytes: 100
        )
    }

    private func storageTarget(
        id: String,
        path: String,
        action: CleanupAction
    ) -> CleanupTarget {
        CleanupTarget(
            kind: .filesystem,
            identifier: id,
            name: id,
            detail: path,
            category: action == .moveToTrash ? .archive : .derivedData,
            riskTier: action == .moveToTrash ? .guarded : .rebuildable,
            action: action,
            path: path,
            runtimeIdentifier: "",
            lastUsedAt: now,
            sizeBytes: 100,
            fingerprint: .filesystem(
                path: path,
                sizeBytes: 100,
                modifiedAt: now
            ),
            selectedByDefault: action == .deletePermanently
        )
    }

    private func inventory(
        deviceIDs: [String] = [],
        runtimeIDs: [String] = [],
        bootedDeviceIDs: Set<String> = [],
        outdatedRuntimeIDs: Set<String>? = nil,
        hasActiveTests: Bool = false,
        available: Int64 = 100
    ) -> CleanupInventory {
        CleanupInventory(
            devices: deviceIDs.map { id in
                CleanupDeviceRecord(
                    identifier: id,
                    name: id,
                    runtimeIdentifier: "runtime.current",
                    state: bootedDeviceIDs.contains(id) ? "Booted" : "Shutdown",
                    lastUsedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
                    dataPath: "/Devices/\(id)/data",
                    sizeBytes: 100
                )
            },
            runtimes: runtimeIDs.map { id in
                CleanupRuntimeRecord(
                    identifier: id,
                    runtimeIdentifier: "runtime.\(id)",
                    name: id,
                    build: "1",
                    sizeBytes: 100
                )
            },
            outdatedRuntimeIDs: outdatedRuntimeIDs ?? Set(runtimeIDs),
            hasActiveXcodeTests: hasActiveTests,
            availableBytes: available
        )
    }
}

private final class SequenceStorageProvider:
    XcodeStorageInventoryProviding,
    @unchecked Sendable
{
    private var inventories: [XcodeStorageInventory]

    init(inventories: [XcodeStorageInventory]) {
        self.inventories = inventories
    }

    func inventory(now: Date) throws -> XcodeStorageInventory {
        guard !inventories.isEmpty else { throw TestError.inventory }
        return inventories.removeFirst()
    }
}

private final class RecordingFileOperator:
    CleanupFileOperating,
    @unchecked Sendable
{
    enum Call: Equatable {
        case delete(String)
        case trash(String)
    }

    private(set) var calls = [Call]()

    func delete(_ url: URL) throws {
        calls.append(.delete(url.path))
    }

    func trash(_ url: URL) throws {
        calls.append(.trash(url.path))
    }
}

private enum TestError: Error {
    case inventory
    case delete
}

private final class SequenceCleanupProvider:
    CleanupInventoryProviding,
    @unchecked Sendable
{
    enum Call: Equatable {
        case inventory
        case deleteDevice(String)
        case deleteRuntime(String)
    }

    private var inventories: [Result<CleanupInventory, Error>]
    private let deviceDeleteErrors: [String: Error]
    private(set) var calls: [Call] = []

    init(
        inventories: [Result<CleanupInventory, Error>],
        deviceDeleteErrors: [String: Error] = [:]
    ) {
        self.inventories = inventories
        self.deviceDeleteErrors = deviceDeleteErrors
    }

    func inventory() throws -> CleanupInventory {
        calls.append(.inventory)
        guard !inventories.isEmpty else { throw TestError.inventory }
        return try inventories.removeFirst().get()
    }

    func deleteDevice(id: String) throws {
        calls.append(.deleteDevice(id))
        if let error = deviceDeleteErrors[id] { throw error }
    }

    func deleteRuntime(id: String) throws {
        calls.append(.deleteRuntime(id))
    }
}
