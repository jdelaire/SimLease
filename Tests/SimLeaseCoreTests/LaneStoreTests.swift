import Foundation
import XCTest
@testable import SimLeaseCore

final class LaneStoreTests: XCTestCase {
    func testDefaultsToTwoLanesAndPrivateDirectories() throws {
        let fixture = try Fixture()

        XCTAssertEqual(
            try fixture.store.readState(),
            LanePersistentState(
                schemaVersion: 1,
                configuration: LaneConfiguration(maxActive: 2),
                reservations: [],
                managedDevices: []
            )
        )
        XCTAssertEqual(permissions(fixture.paths.laneRoot), 0o700)
        XCTAssertEqual(permissions(fixture.paths.laneDescriptors), 0o700)
    }

    func testStateAndDescriptorRoundTripWithPrivateFiles() throws {
        let fixture = try Fixture()
        let descriptor = makeDescriptor()
        let descriptorURL = try fixture.store.writeDescriptor(descriptor)
        XCTAssertEqual(descriptorURL.lastPathComponent, "lane-1.json")
        let state = LanePersistentState(
            schemaVersion: 1,
            configuration: LaneConfiguration(maxActive: 2),
            reservations: [makeReservation(descriptorURL: descriptorURL)],
            managedDevices: [makeManagedDevice()]
        )

        try fixture.store.writeState(state)

        XCTAssertEqual(try fixture.store.readState(), state)
        XCTAssertEqual(try fixture.store.readDescriptor(at: descriptorURL), descriptor)
        XCTAssertEqual(permissions(fixture.paths.laneState), 0o600)
        XCTAssertEqual(permissions(descriptorURL), 0o600)
    }

    func testRejectsForeignDescriptorAndCorruptState() throws {
        let fixture = try Fixture()
        let foreign = fixture.root.appendingPathComponent("foreign.json")
        try Data("{}".utf8).write(to: foreign)

        XCTAssertThrowsError(try fixture.store.readDescriptor(at: foreign))

        try Data("not-json".utf8).write(to: fixture.paths.laneState)
        XCTAssertThrowsError(try fixture.store.readState())
    }

    func testRejectsDuplicateSlotsAndUnknownManagedDevice() throws {
        let fixture = try Fixture()
        let descriptorURL = try fixture.store.writeDescriptor(makeDescriptor())
        let first = makeReservation(descriptorURL: descriptorURL)
        let duplicate = LaneReservation(
            laneID: "lane-2",
            slot: first.slot,
            token: "TOKEN-2",
            project: first.project,
            threadID: nil,
            threadTitle: nil,
            udid: "UDID-2",
            descriptorPath: descriptorURL.path,
            generation: 1,
            acquiredAt: first.acquiredAt,
            lastActivityAt: first.lastActivityAt,
            expiresAt: first.expiresAt
        )

        XCTAssertThrowsError(try fixture.store.writeState(
            LanePersistentState(
                schemaVersion: 1,
                configuration: LaneConfiguration(maxActive: 2),
                reservations: [first, duplicate],
                managedDevices: [makeManagedDevice()]
            )
        ))
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class Fixture {
    let root: URL
    let paths: LeasePaths
    let store: LaneStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = LeasePaths(root: root.appendingPathComponent("cache", isDirectory: true))
        store = try LaneStore(paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeDescriptor() -> LaneDescriptor {
    LaneDescriptor(
        laneID: "lane-1",
        slot: 1,
        token: "TOKEN-1",
        project: "ExplorerDex",
        threadID: "thread-1",
        threadTitle: "Simulator validation",
        udid: "UDID-1",
        deviceTypeIdentifier: "TYPE-1",
        deviceTypeName: "iPhone 17 Pro",
        runtimeIdentifier: "RUNTIME-1",
        runtimeName: "iOS 27.0",
        derivedDataPath: "/tmp/DerivedData",
        acquiredAt: Date(timeIntervalSince1970: 1_000),
        lastActivityAt: Date(timeIntervalSince1970: 1_100),
        expiresAt: Date(timeIntervalSince1970: 8_300)
    )
}

private func makeReservation(descriptorURL: URL) -> LaneReservation {
    LaneReservation(
        laneID: "lane-1",
        slot: 1,
        token: "TOKEN-1",
        project: "ExplorerDex",
        threadID: "thread-1",
        threadTitle: "Simulator validation",
        udid: "UDID-1",
        descriptorPath: descriptorURL.path,
        generation: 1,
        acquiredAt: Date(timeIntervalSince1970: 1_000),
        lastActivityAt: Date(timeIntervalSince1970: 1_100),
        expiresAt: Date(timeIntervalSince1970: 8_300)
    )
}

private func makeManagedDevice() -> ManagedSimulatorRecord {
    ManagedSimulatorRecord(
        udid: "UDID-1",
        name: "[SimLease] ExplorerDex 1",
        deviceTypeIdentifier: "TYPE-1",
        deviceTypeName: "iPhone 17 Pro",
        runtimeIdentifier: "RUNTIME-1",
        runtimeName: "iOS 27.0",
        expectedDataPath: "/tmp/Devices/UDID-1",
        createdAt: Date(timeIntervalSince1970: 1_000),
        lifecycle: .reserved
    )
}
