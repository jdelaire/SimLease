import Foundation
import XCTest
@testable import SimLeaseCore

final class DeviceDataCleanupTests: XCTestCase {
    private let id = "11111111-1111-4111-8111-111111111111"
    private var root: URL!
    private var data: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        data = root.appendingPathComponent("Devices/\(id)/data", isDirectory: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: data.appendingPathComponent("Library/Caches/blob"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testPlannerListsOnlyShutDownDevicesAboveThreshold() {
        let planner = CleanupPlanner(devicesRoot: root.appendingPathComponent("Devices"), minimumDeviceDataBytes: 1)
        let targets = planner.deviceDataTargets(inventory(state: "Shutdown"))
        XCTAssertEqual(targets.map(\.identifier), ["device-data:\(id)"])
        XCTAssertEqual(targets.first?.kind, .deviceData)
        XCTAssertTrue(planner.deviceDataTargets(inventory(state: "Booted")).isEmpty)
        XCTAssertTrue(CleanupPlanner(devicesRoot: root.appendingPathComponent("Devices"), minimumDeviceDataBytes: 1 << 30).deviceDataTargets(inventory(state: "Shutdown")).isEmpty)
        XCTAssertTrue(CleanupPlanner(devicesRoot: root.appendingPathComponent("Other"), minimumDeviceDataBytes: 1).deviceDataTargets(inventory(state: "Shutdown")).isEmpty)
    }

    func testExecutorRevalidatesStateAndDigestBeforeClearing() throws {
        let planner = CleanupPlanner(devicesRoot: root.appendingPathComponent("Devices"), minimumDeviceDataBytes: 1)
        let target = try XCTUnwrap(planner.deviceDataTargets(inventory(state: "Shutdown")).first)
        let plan = CleanupPlan(id: "ABC123", createdAt: Date(), expiresAt: Date(), devices: [], runtimes: [], storage: [target], protected: [], estimatedBytes: 0, availableBytesBefore: nil)
        let blob = data.appendingPathComponent("Library/Caches/blob")

        let booted = CleanupExecutor(provider: DeviceDataProvider(inventory(state: "Booted")), planner: planner)
        XCTAssertEqual(try booted.apply(plan: plan, now: Date()).items.map(\.message), ["Device is no longer eligible"])

        try Data(repeating: 2, count: 8192).write(to: data.appendingPathComponent("Library/Caches/new"))
        let changed = CleanupExecutor(provider: DeviceDataProvider(inventory(state: "Shutdown")), planner: planner)
        XCTAssertEqual(try changed.apply(plan: plan, now: Date()).items.map(\.message), ["Target changed since review"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))

        try FileManager.default.removeItem(at: data.appendingPathComponent("Library/Caches/new"))
        let fresh = try XCTUnwrap(planner.deviceDataTargets(inventory(state: "Shutdown")).first)
        let current = CleanupPlan(id: "ABC123", createdAt: Date(), expiresAt: Date(), devices: [], runtimes: [], storage: [fresh], protected: [], estimatedBytes: 0, availableBytesBefore: nil)
        XCTAssertEqual(try changed.apply(plan: current, now: Date()).items.map(\.outcome), [.deleted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("Library/Caches").path))
    }

    private func inventory(state: String) -> CleanupInventory {
        CleanupInventory(
            devices: [CleanupDeviceRecord(identifier: id, name: "iPhone", runtimeIdentifier: "runtime", state: state, lastUsedAt: nil, dataPath: data.path, sizeBytes: nil)],
            runtimes: [], outdatedRuntimeIDs: [], hasActiveXcodeTests: false, availableBytes: nil
        )
    }
}

private struct DeviceDataProvider: CleanupInventoryProviding {
    let value: CleanupInventory
    init(_ value: CleanupInventory) { self.value = value }
    func inventory() throws -> CleanupInventory { value }
    func deleteDevice(id: String) throws {}
    func deleteRuntime(id: String) throws {}
}
