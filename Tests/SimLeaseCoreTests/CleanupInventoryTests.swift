import Foundation
import XCTest
@testable import SimLeaseCore

final class CleanupInventoryTests: XCTestCase {
    func testDecodesLiteralDeviceAndRuntimeInventory() throws {
        let devices = Data(#"""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{
              "dataPath": "/Users/test/Library/Developer/CoreSimulator/Devices/DEVICE-1/data",
              "dataPathSize": 4096,
              "udid": "DEVICE-1",
              "lastUsedAt": "2026-06-01T00:00:00Z",
              "isAvailable": true,
              "state": "Shutdown",
              "name": "iPhone 17 Pro"
            }]
          }
        }
        """#.utf8)
        let runtimes = Data(#"""
        {
          "RUNTIME-IMAGE-1": {
            "build": "23T239",
            "deletable": true,
            "identifier": "RUNTIME-IMAGE-1",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-4",
            "sizeBytes": 3931694170,
            "version": "26.4"
          }
        }
        """#.utf8)

        let decodedDevices = try CleanupInventoryParser.decodeDevices(from: devices)
        let decodedRuntimes = try CleanupInventoryParser.decodeRuntimes(from: runtimes)

        XCTAssertEqual(decodedDevices.first?.identifier, "DEVICE-1")
        XCTAssertEqual(
            decodedDevices.first?.runtimeIdentifier,
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        )
        XCTAssertEqual(decodedDevices.first?.sizeBytes, 4_096)
        XCTAssertEqual(decodedRuntimes.first?.identifier, "RUNTIME-IMAGE-1")
        XCTAssertEqual(decodedRuntimes.first?.build, "23T239")
        XCTAssertEqual(decodedRuntimes.first?.sizeBytes, 3_931_694_170)
    }

    func testDryRunMapsExactKnownIdentifierTokens() throws {
        let runtimes = [
            CleanupRuntimeRecord(
                identifier: "RUNTIME-IMAGE-1",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-4",
                name: "watchOS 26.4",
                build: "23T239",
                sizeBytes: 100
            ),
        ]

        let identifiers = try CleanupInventoryParser.decodeOutdatedRuntimeIDs(
            from: "Would delete RUNTIME-IMAGE-1\n",
            runtimes: runtimes
        )

        XCTAssertEqual(identifiers, ["RUNTIME-IMAGE-1"])
    }

    func testDryRunAcceptsNoMatchingImagesMessage() throws {
        let identifiers = try CleanupInventoryParser.decodeOutdatedRuntimeIDs(
            from: "No matching images found to delete\n",
            runtimes: []
        )

        XCTAssertEqual(identifiers, [])
    }

    func testDryRunRejectsUnknownLines() {
        XCTAssertThrowsError(
            try CleanupInventoryParser.decodeOutdatedRuntimeIDs(
                from: "Would delete unknown-runtime\n",
                runtimes: []
            )
        ) {
            XCTAssertEqual(
                $0 as? CleanupInventoryError,
                .invalidRuntimeDryRun
            )
        }
    }

    func testProviderUsesOnlyApprovedInventoryAndDeleteCommands() throws {
        let runner = RecordingCleanupCommandRunner()
        let provider = ProcessCleanupInventoryProvider(
            runner: runner,
            xcrunURL: URL(fileURLWithPath: "/test/xcrun"),
            psURL: URL(fileURLWithPath: "/test/ps"),
            environment: ["KEEP": "1"],
            capacityURL: FileManager.default.temporaryDirectory
        )

        _ = try provider.inventory()
        try provider.deleteDevice(id: "DEVICE-1")
        try provider.deleteRuntime(id: "RUNTIME-1")

        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["simctl", "list", "devices", "-j"],
            ["simctl", "runtime", "list", "-j"],
            ["simctl", "runtime", "delete", "--outdated", "--dry-run"],
            ["-axo", "command="],
            ["simctl", "delete", "DEVICE-1"],
            ["simctl", "runtime", "delete", "RUNTIME-1"],
        ])
        XCTAssertEqual(runner.calls[0].environment["SIMLEASE_HELD"], "1")
        XCTAssertEqual(runner.calls[4].environment["SIMLEASE_HELD"], "1")
    }

    func testProviderAcceptsLiteralNoMatchingDryRunExitTwo() throws {
        let runner = RecordingCleanupCommandRunner(
            dryRunOutput: CleanupCommandOutput(
                exitCode: 2,
                stdout: "",
                stderr: "No matching images found to delete\n"
            )
        )
        let provider = ProcessCleanupInventoryProvider(
            runner: runner,
            xcrunURL: URL(fileURLWithPath: "/test/xcrun"),
            psURL: URL(fileURLWithPath: "/test/ps"),
            environment: [:],
            capacityURL: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(try provider.inventory().outdatedRuntimeIDs, [])
    }
}

private final class RecordingCleanupCommandRunner:
    CleanupCommandRunning,
    @unchecked Sendable
{
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private(set) var calls: [Call] = []
    private let dryRunOutput: CleanupCommandOutput

    init(
        dryRunOutput: CleanupCommandOutput = CleanupCommandOutput(
            exitCode: 0,
            stdout: "",
            stderr: ""
        )
    ) {
        self.dryRunOutput = dryRunOutput
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> CleanupCommandOutput {
        calls.append(
            Call(
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        )
        switch arguments {
        case ["simctl", "list", "devices", "-j"]:
            return CleanupCommandOutput(
                exitCode: 0,
                stdout: #"{"devices":{}}"#,
                stderr: ""
            )
        case ["simctl", "runtime", "list", "-j"]:
            return CleanupCommandOutput(exitCode: 0, stdout: "{}", stderr: "")
        case ["simctl", "runtime", "delete", "--outdated", "--dry-run"]:
            return dryRunOutput
        case ["-axo", "command="]:
            return CleanupCommandOutput(exitCode: 0, stdout: "", stderr: "")
        default:
            return CleanupCommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
    }
}
