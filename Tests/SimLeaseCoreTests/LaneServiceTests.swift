import Foundation
import XCTest
@testable import SimLeaseCore

final class LaneServiceTests: XCTestCase {
    func testAcquireCreatesManagedDeviceAndReturnsIsolatedGuidance() throws {
        let fixture = try ServiceFixture()

        let result = try fixture.service.acquire(
            request: LaneAcquireRequest(
                project: "ExplorerDex",
                deviceType: "iPhone 17 Pro",
                runtime: "latest"
            ),
            identity: fixture.identity
        )

        let lane = try XCTUnwrap(result.lane)
        XCTAssertEqual(lane.slot, 1)
        XCTAssertEqual(lane.udid, "CREATED-1")
        XCTAssertEqual(result.state, .acquired)
        XCTAssertEqual(result.environment["SIMLEASE_LANE_FILE"], fixture.paths.laneDescriptors.appendingPathComponent("lane-1.json").path)
        XCTAssertTrue(result.xcodebuildArguments.contains("platform=iOS Simulator,id=CREATED-1"))
        XCTAssertTrue(try XCTUnwrap(result.derivedDataPath).contains("ExplorerDex/lane-1"))
        XCTAssertTrue(try XCTUnwrap(result.resultBundlePath).hasSuffix(".xcresult"))
        XCTAssertEqual(fixture.provider.created.count, 1)
        XCTAssertEqual(try fixture.store.readState().reservations.count, 1)
    }

    func testTwoLanesFillCapacityAndThirdAcquireChangesNothing() throws {
        let fixture = try ServiceFixture()
        _ = try fixture.acquire(project: "First")
        _ = try fixture.acquire(project: "Second")
        let stateBefore = try fixture.store.readState()

        XCTAssertThrowsError(try fixture.acquire(project: "Third")) {
            guard case LaneServiceError.capacityFull = $0 else {
                return XCTFail("expected capacityFull, got \($0)")
            }
        }
        XCTAssertEqual(try fixture.store.readState(), stateBefore)
        XCTAssertEqual(fixture.provider.created.count, 2)
    }

    func testReducingCapacityNeverEvictsExistingLanes() throws {
        let fixture = try ServiceFixture()
        let first = try fixture.acquire(project: "First")
        let second = try fixture.acquire(project: "Second")

        let report = try fixture.service.configure(maxActive: 1)

        XCTAssertEqual(report.configuration.maxActive, 1)
        XCTAssertEqual(report.reservationCount, 2)
        XCTAssertEqual(try fixture.store.readState().reservations.count, 2)
        XCTAssertThrowsError(try fixture.acquire(project: "Third"))

        _ = try fixture.service.release(
            descriptorURL: URL(fileURLWithPath: try XCTUnwrap(
                first.environment["SIMLEASE_LANE_FILE"]
            )),
            identity: fixture.identity
        )
        XCTAssertThrowsError(try fixture.acquire(project: "Third"))
        _ = try fixture.service.release(
            descriptorURL: URL(fileURLWithPath: try XCTUnwrap(
                second.environment["SIMLEASE_LANE_FILE"]
            )),
            identity: fixture.identity
        )
        XCTAssertNoThrow(try fixture.acquire(project: "Third"))
    }

    func testRenewAndReleaseValidateDescriptorAndNeverDelete() throws {
        let fixture = try ServiceFixture()
        let result = try fixture.acquire(project: "ExplorerDex")
        let descriptorPath = try XCTUnwrap(result.environment["SIMLEASE_LANE_FILE"])
        let descriptorURL = URL(fileURLWithPath: descriptorPath)

        let renewed = try fixture.service.renew(
            descriptorURL: descriptorURL,
            now: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(renewed.lastActivityAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(renewed.expiresAt, Date(timeIntervalSince1970: 9_200))

        let released = try fixture.service.release(
            descriptorURL: descriptorURL,
            identity: fixture.identity
        )

        XCTAssertEqual(released.state, "idle")
        XCTAssertEqual(try fixture.store.readState().reservations, [])
        XCTAssertEqual(fixture.provider.shutdowns, [released.udid])
        XCTAssertEqual(fixture.provider.deletions, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptorPath))
    }

    func testExpiredRecoveryPlanApplyReleasesLaneAndNeverDeletes() throws {
        let fixture = try ServiceFixture()
        _ = try fixture.acquire(project: "ExplorerDex")

        let plan = try fixture.service.createRecoveryPlan(
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 8_201)
        )
        let result = try fixture.service.applyRecovery(
            planID: plan.id,
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 8_202)
        )

        XCTAssertEqual(result.state, "idle")
        XCTAssertEqual(try fixture.store.readState().reservations, [])
        XCTAssertEqual(fixture.provider.shutdowns, ["CREATED-1"])
        XCTAssertEqual(fixture.provider.deletions, [])
        XCTAssertThrowsError(
            try fixture.service.applyRecovery(
                planID: plan.id,
                laneID: "lane-1",
                now: Date(timeIntervalSince1970: 8_203)
            )
        )
    }

    func testFailedRecoveryApplyPreservesPlanForRetry() throws {
        let fixture = try ServiceFixture()
        _ = try fixture.acquire(project: "ExplorerDex")

        let plan = try fixture.service.createRecoveryPlan(
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 8_201)
        )
        XCTAssertThrowsError(try fixture.service.applyRecovery(
            planID: plan.id,
            laneID: "lane-9",
            now: Date(timeIntervalSince1970: 8_202)
        )) {
            guard case LaneServiceError.targetMismatch = $0 else {
                return XCTFail("expected targetMismatch, got \($0)")
            }
        }

        let result = try fixture.service.applyRecovery(
            planID: plan.id,
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 8_203)
        )

        XCTAssertEqual(result.state, "idle")
        XCTAssertEqual(try fixture.store.readState().reservations, [])
    }

    func testMissingDeviceRecoveryRemovesRecordWithoutLeak() throws {
        let fixture = try ServiceFixture()
        _ = try fixture.acquire(project: "ExplorerDex")
        fixture.provider.removeDevice(udid: "CREATED-1")

        let plan = try fixture.service.createRecoveryPlan(
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 8_201)
        )
        let result = try fixture.service.applyRecovery(
            planID: plan.id,
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 8_202)
        )

        XCTAssertEqual(result.state, "removed")
        XCTAssertEqual(try fixture.store.readState().reservations, [])
        XCTAssertEqual(try fixture.store.readState().managedDevices, [])
    }

    func testGhostDisposalCleansStaleRecord() throws {
        let fixture = try ServiceFixture()
        let acquired = try fixture.acquire(project: "ExplorerDex")
        let descriptorURL = URL(fileURLWithPath: try XCTUnwrap(
            acquired.environment["SIMLEASE_LANE_FILE"]
        ))
        _ = try fixture.service.release(
            descriptorURL: descriptorURL,
            identity: fixture.identity
        )
        fixture.provider.removeDevice(udid: "CREATED-1")

        let plan = try fixture.service.createDisposalPlan(
            udid: "CREATED-1",
            now: Date(timeIntervalSince1970: 2_000)
        )
        let result = try fixture.service.applyDisposal(
            planID: plan.id,
            udid: "CREATED-1",
            now: Date(timeIntervalSince1970: 2_001)
        )

        XCTAssertTrue(result.deleted)
        XCTAssertEqual(try fixture.store.readState().managedDevices, [])
        XCTAssertEqual(fixture.provider.deletions, [])
    }

    func testRecoveryPlanRejectsRecentLaneAndApplyRejectsResumedActivity() throws {
        let fixture = try ServiceFixture()
        let acquired = try fixture.acquire(project: "ExplorerDex")
        XCTAssertThrowsError(try fixture.service.createRecoveryPlan(
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 2_000)
        )) {
            guard case LaneServiceError.laneRecoveryTooRecent = $0 else {
                return XCTFail("expected laneRecoveryTooRecent, got \($0)")
            }
        }

        let plan = try fixture.service.createRecoveryPlan(
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 8_201)
        )
        _ = try fixture.service.renew(
            descriptorURL: URL(fileURLWithPath: try XCTUnwrap(
                acquired.environment["SIMLEASE_LANE_FILE"]
            )),
            now: Date(timeIntervalSince1970: 8_202)
        )
        XCTAssertThrowsError(try fixture.service.applyRecovery(
            planID: plan.id,
            laneID: "lane-1",
            now: Date(timeIntervalSince1970: 8_203)
        )) {
            XCTAssertEqual(
                $0 as? LaneServiceError,
                .recoveryRequired(laneID: "lane-1")
            )
        }
        XCTAssertEqual(try fixture.store.readState().reservations.count, 1)
        XCTAssertEqual(fixture.provider.deletions, [])
    }

    func testDisposalDeletesOnlyReviewedIdleManagedDevice() throws {
        let fixture = try ServiceFixture()
        let acquired = try fixture.acquire(project: "ExplorerDex")
        _ = try fixture.service.release(
            descriptorURL: URL(fileURLWithPath: try XCTUnwrap(
                acquired.environment["SIMLEASE_LANE_FILE"]
            )),
            identity: fixture.identity
        )

        let plan = try fixture.service.createDisposalPlan(
            udid: "CREATED-1",
            now: Date(timeIntervalSince1970: 2_000)
        )
        let result = try fixture.service.applyDisposal(
            planID: plan.id,
            udid: "CREATED-1",
            now: Date(timeIntervalSince1970: 2_001)
        )

        XCTAssertTrue(result.deleted)
        XCTAssertEqual(fixture.provider.deletions, ["CREATED-1"])
        XCTAssertEqual(try fixture.store.readState().managedDevices, [])
    }

    func testDisposalRefusesReservedOrChangedDevice() throws {
        let fixture = try ServiceFixture()
        let acquired = try fixture.acquire(project: "ExplorerDex")
        XCTAssertThrowsError(try fixture.service.createDisposalPlan(
            udid: "CREATED-1",
            now: Date(timeIntervalSince1970: 2_000)
        ))
        _ = try fixture.service.release(
            descriptorURL: URL(fileURLWithPath: try XCTUnwrap(
                acquired.environment["SIMLEASE_LANE_FILE"]
            )),
            identity: fixture.identity
        )
        let plan = try fixture.service.createDisposalPlan(
            udid: "CREATED-1",
            now: Date(timeIntervalSince1970: 2_000)
        )
        fixture.provider.setState(udid: "CREATED-1", state: "Booted")

        XCTAssertThrowsError(try fixture.service.applyDisposal(
            planID: plan.id,
            udid: "CREATED-1",
            now: Date(timeIntervalSince1970: 2_001)
        ))
        XCTAssertEqual(fixture.provider.deletions, [])
        XCTAssertEqual(try fixture.store.readState().managedDevices.count, 1)
    }
}

private final class ServiceFixture {
    let root: URL
    let paths: LeasePaths
    let store: LaneStore
    let provider = LaneProviderStub()
    let service: LaneService
    let identity: LeaseIdentity

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = LeasePaths(root: root.appendingPathComponent("cache", isDirectory: true))
        store = try LaneStore(paths: paths)
        let metadata = try MetadataStore(paths: paths)
        let timing = LeaseTiming(
            timeout: .milliseconds(200),
            reportInterval: .milliseconds(50),
            pollInterval: .milliseconds(5)
        )
        var token = 0
        let planStore = try LanePlanStore(paths: paths)
        var planID = 0
        service = LaneService(
            paths: paths,
            store: store,
            provider: provider,
            coordinator: LeaseCoordinator(paths: paths, store: metadata, timing: timing),
            laneLocks: LaneLockCoordinator(paths: paths, timing: timing),
            planStore: planStore,
            now: { Date(timeIntervalSince1970: 1_000) },
            tokenGenerator: {
                token += 1
                return "TOKEN-\(token)"
            },
            planIDGenerator: {
                planID += 1
                return String(format: "P%05d", planID)
            }
        )
        identity = LeaseIdentity(
            pid: 123,
            cwd: "/tmp/ExplorerDex",
            project: "ExplorerDex",
            command: ["simlease", "lane", "acquire"],
            source: .codex,
            threadID: "thread-1",
            threadTitle: "Simulator validation"
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func acquire(project: String) throws -> LaneAcquireResult {
        try service.acquire(
            request: LaneAcquireRequest(
                project: project,
                deviceType: "iPhone 17 Pro",
                runtime: "latest"
            ),
            identity: identity
        )
    }
}

private final class LaneProviderStub: LaneSimulatorProviding, @unchecked Sendable {
    private(set) var devices: [LaneSimulatorDevice] = []
    private(set) var created: [String] = []
    private(set) var shutdowns: [String] = []
    private(set) var deletions: [String] = []

    func inventory() throws -> LaneSimulatorInventory {
        LaneSimulatorInventory(
            runtimes: [LaneRuntime(identifier: "RUNTIME-27", name: "iOS 27.0", version: "27.0", isAvailable: true)],
            deviceTypes: [LaneDeviceType(identifier: "TYPE-17", name: "iPhone 17 Pro")],
            devices: devices
        )
    }

    func createDevice(name: String, deviceTypeID: String, runtimeID: String) throws -> String {
        let udid = "CREATED-\(created.count + 1)"
        created.append(udid)
        devices.append(LaneSimulatorDevice(
            udid: udid,
            name: name,
            state: "Booted",
            runtimeIdentifier: runtimeID,
            deviceTypeIdentifier: deviceTypeID,
            dataPath: "/tmp/Devices/\(udid)"
        ))
        return udid
    }

    func shutdownDevice(udid: String) throws {
        shutdowns.append(udid)
        devices = devices.map {
            guard $0.udid == udid else { return $0 }
            return LaneSimulatorDevice(
                udid: $0.udid,
                name: $0.name,
                state: "Shutdown",
                runtimeIdentifier: $0.runtimeIdentifier,
                deviceTypeIdentifier: $0.deviceTypeIdentifier,
                dataPath: $0.dataPath
            )
        }
    }

    func deleteDevice(udid: String) throws {
        deletions.append(udid)
        devices.removeAll { $0.udid == udid }
    }

    func removeDevice(udid: String) {
        devices.removeAll { $0.udid == udid }
    }

    func setState(udid: String, state: String) {
        devices = devices.map {
            guard $0.udid == udid else { return $0 }
            return LaneSimulatorDevice(
                udid: $0.udid,
                name: $0.name,
                state: state,
                runtimeIdentifier: $0.runtimeIdentifier,
                deviceTypeIdentifier: $0.deviceTypeIdentifier,
                dataPath: $0.dataPath
            )
        }
    }
}
