import Foundation
import XCTest
@testable import SimLeaseCore

final class LaneSimulatorProviderTests: XCTestCase {
    func testInventoryDecodesLiteralCoreSimulatorPayloads() throws {
        let runner = RecordingLaneRunner()
        let provider = ProcessLaneSimulatorProvider(
            runner: runner,
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            environment: ["PATH": "/test"]
        )

        let inventory = try provider.inventory()

        XCTAssertEqual(inventory.runtimes.map(\.identifier), ["RUNTIME-26", "RUNTIME-27"])
        XCTAssertEqual(inventory.deviceTypes, [
            LaneDeviceType(identifier: "TYPE-17", name: "iPhone 17 Pro")
        ])
        XCTAssertEqual(inventory.devices, [
            LaneSimulatorDevice(
                udid: "UDID-1",
                name: "[SimLease] App 1",
                state: "Shutdown",
                runtimeIdentifier: "RUNTIME-27",
                deviceTypeIdentifier: "TYPE-17",
                dataPath: "/tmp/Devices/UDID-1"
            )
        ])
        XCTAssertTrue(runner.calls.allSatisfy {
            $0.environment["SIMLEASE_HELD"] == "1"
        })
    }

    func testResolvesLatestAvailableRuntimeAndExactDeviceType() throws {
        let inventory = try ProcessLaneSimulatorProvider(
            runner: RecordingLaneRunner(),
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun")
        ).inventory()

        XCTAssertEqual(try inventory.resolveRuntime("latest").identifier, "RUNTIME-27")
        XCTAssertEqual(try inventory.resolveRuntime("RUNTIME-26").version, "26.5")
        XCTAssertEqual(
            try inventory.resolveDeviceType("iphone 17 pro").identifier,
            "TYPE-17"
        )
        XCTAssertThrowsError(try inventory.resolveRuntime("RUNTIME-MISSING"))
        XCTAssertThrowsError(try inventory.resolveDeviceType("iPhone 99"))
    }

    func testUsesOnlyExactManagedMutationCommands() throws {
        let runner = RecordingLaneRunner()
        let provider = ProcessLaneSimulatorProvider(
            runner: runner,
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun")
        )

        XCTAssertEqual(
            try provider.createDevice(
                name: "[SimLease] ExplorerDex 1",
                deviceTypeID: "TYPE-17",
                runtimeID: "RUNTIME-27"
            ),
            "CREATED-UDID"
        )
        try provider.shutdownDevice(udid: "CREATED-UDID")
        try provider.deleteDevice(udid: "CREATED-UDID")

        XCTAssertEqual(runner.calls.suffix(3).map(\.arguments), [
            ["simctl", "create", "[SimLease] ExplorerDex 1", "TYPE-17", "RUNTIME-27"],
            ["simctl", "shutdown", "CREATED-UDID"],
            ["simctl", "delete", "CREATED-UDID"],
        ])
    }
}

private final class RecordingLaneRunner: CleanupCommandRunning, @unchecked Sendable {
    struct Call {
        let arguments: [String]
        let environment: [String: String]
    }

    private(set) var calls: [Call] = []

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> CleanupCommandOutput {
        calls.append(Call(arguments: arguments, environment: environment))
        switch arguments {
        case ["simctl", "list", "runtimes", "-j"]:
            return output(#"{"runtimes":[{"identifier":"RUNTIME-27","name":"iOS 27.0","version":"27.0","isAvailable":true},{"identifier":"RUNTIME-28","name":"iOS 28.0","version":"28.0","isAvailable":false},{"identifier":"RUNTIME-26","name":"iOS 26.5","version":"26.5","isAvailable":true}]}"#)
        case ["simctl", "list", "devicetypes", "-j"]:
            return output(#"{"devicetypes":[{"identifier":"TYPE-17","name":"iPhone 17 Pro"}]}"#)
        case ["simctl", "list", "devices", "-j"]:
            return output(#"{"devices":{"RUNTIME-27":[{"udid":"UDID-1","name":"[SimLease] App 1","state":"Shutdown","deviceTypeIdentifier":"TYPE-17","dataPath":"/tmp/Devices/UDID-1"}]}}"#)
        case ["simctl", "create", "[SimLease] ExplorerDex 1", "TYPE-17", "RUNTIME-27"]:
            return output("CREATED-UDID\n")
        case ["simctl", "shutdown", "CREATED-UDID"],
             ["simctl", "delete", "CREATED-UDID"]:
            return output("")
        default:
            return CleanupCommandOutput(exitCode: 2, stdout: "", stderr: "unexpected")
        }
    }

    private func output(_ stdout: String) -> CleanupCommandOutput {
        CleanupCommandOutput(exitCode: 0, stdout: stdout, stderr: "")
    }
}
