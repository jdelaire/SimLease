import XCTest
@testable import SimLeaseCore

final class SimulatorUsageTests: XCTestCase {
    func testReservedDevicesLeadAndIdleShutdownDevicesStayHidden() throws {
        let owned = "11111111-1111-4111-8111-111111111111"
        let borrowed = "22222222-2222-4222-8222-222222222222"
        let booted = "33333333-3333-4333-8333-333333333333"
        let idle = "44444444-4444-4444-8444-444444444444"
        let queued = "55555555-5555-4555-8555-555555555555"
        let missing = "66666666-6666-4666-8666-666666666666"
        let inventory = [
            device(owned, name: "Owned", state: "Booted", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4"),
            device(borrowed, name: "Borrowed", state: "Booted"),
            device(booted, name: "Another", state: "Booted"),
            device(idle, name: "Idle", state: "Shutdown"),
            device(queued, name: "Queued", state: "Shutdown"),
        ]
        let task = SimulatorTaskRecord(
            token: "token", owner: try ProcessReference.current(),
            deviceIDs: [owned, borrowed, missing].map { $0.lowercased() }, ownedDeviceIDs: [owned.lowercased()], phase: .running
        )

        let usage = SimulatorUsage.build(inventory: inventory, task: task, relevantIDs: [queued.lowercased()])

        XCTAssertEqual(usage.map(\.name), ["Borrowed", "Owned", "Unknown simulator", "Another", "Queued"])
        XCTAssertEqual(usage.map(\.reservation), [.borrowed, .owned, .borrowed, .unreserved, .unreserved])
        XCTAssertEqual(usage[1].runtime, "iOS 27.2")
        XCTAssertEqual(usage[2].state, "Missing")
        XCTAssertEqual(SimulatorUsage.build(inventory: inventory, task: nil).map(\.name), ["Another", "Borrowed", "Owned"])
    }

    func testWarmRegistryMarksOnlyBootedUnreservedDevices() {
        let warm = "11111111-1111-4111-8111-111111111111", off = "22222222-2222-4222-8222-222222222222"
        let since = Date(timeIntervalSince1970: 100)
        let usage = SimulatorUsage.build(inventory: [device(warm, name: "Warm", state: "Booted"), device(off, name: "Off", state: "Shutdown")], task: nil, warm: [warm: since, off: since])
        XCTAssertEqual(usage.map(\.reservation), [.warm])
        XCTAssertEqual(usage.first?.warmSince, since)
    }

    func testBootTargetAndRunningApplicationsParsing() {
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(SimulatorCommand.bootTarget(in: ["/usr/bin/xcrun", "simctl", "boot", id.lowercased()]), id)
        XCTAssertNil(SimulatorCommand.bootTarget(in: ["xcrun", "simctl", "boot", id, "--arch=arm64"]))
        XCTAssertNil(SimulatorCommand.bootTarget(in: ["xcrun", "simctl", "shutdown", id]))
        let listing = "PID\tStatus\tLabel\n123\t0\tUIKitApplication:com.example.App[a1b2][rb-legacy]\n-\t0\tcom.apple.springboard\n456\t0\tUIKitApplication:com.example.AppUITests.xctrunner[c3d4][rb-legacy]\n"
        XCTAssertEqual(ProcessSimulatorDeviceManager.runningApplications(listing), ["com.example.App", "com.example.AppUITests.xctrunner"])
    }

    private func device(_ id: String, name: String, state: String, runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-1") -> ManagedSimulatorDevice {
        ManagedSimulatorDevice(id: id, name: name, deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime: runtime, dataPath: "/Devices/\(id)/data", state: state, available: true)
    }
}
