import Foundation
import XCTest
@testable import SimLeaseCore

final class LaneCommandPolicyTests: XCTestCase {
    private let descriptor = LaneDescriptor(
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
        derivedDataPath: "/lane/DerivedData",
        acquiredAt: Date(timeIntervalSince1970: 1_000),
        lastActivityAt: Date(timeIntervalSince1970: 1_000),
        expiresAt: Date(timeIntervalSince1970: 8_200)
    )

    func testValidLaneScopedCommands() throws {
        let commands = [
            ["xcodebuild", "test", "-destination", "platform=iOS Simulator,id=UDID-1", "-derivedDataPath", "/lane/DerivedData"],
            ["xcodebuild", "test", "-destination=platform=iOS Simulator,id=UDID-1", "-derivedDataPath=/lane/DerivedData"],
            ["xcrun", "simctl", "boot", "UDID-1"],
            ["xcrun", "simctl", "install", "UDID-1", "/tmp/App.app"],
            ["axe", "describe-ui", "--udid", "UDID-1"],
            ["axe", "tap", "--label", "Continue", "--udid", "UDID-1"],
        ]

        for command in commands {
            XCTAssertEqual(
                try LaneCommandPolicy.validate(invocation: command, descriptor: descriptor),
                .lane(slot: 1),
                "\(command)"
            )
        }
    }

    func testXcodebuildRequiresExactDestinationAndDerivedData() {
        assertError(
            ["xcodebuild", "test", "-destination", "platform=iOS Simulator,name=iPhone 17 Pro", "-derivedDataPath", "/lane/DerivedData"],
            .targetMismatch(expected: "UDID-1", actual: nil)
        )
        assertError(
            ["xcodebuild", "test", "-destination", "platform=iOS Simulator,id=OTHER", "-derivedDataPath", "/lane/DerivedData"],
            .targetMismatch(expected: "UDID-1", actual: "OTHER")
        )
        assertError(
            ["xcodebuild", "test", "-destination", "platform=iOS Simulator,id=UDID-1"],
            .derivedDataMismatch(expected: "/lane/DerivedData", actual: nil)
        )
        assertError(
            ["xcodebuild", "test", "-destination", "platform=iOS Simulator,id=UDID-1", "-derivedDataPath", "/other"],
            .derivedDataMismatch(expected: "/lane/DerivedData", actual: "/other")
        )
    }

    func testSimctlRejectsWrongTargetAndClassifiesGlobalVerbs() throws {
        assertError(
            ["xcrun", "simctl", "boot", "OTHER"],
            .targetMismatch(expected: "UDID-1", actual: "OTHER")
        )
        assertError(
            ["xcrun", "simctl", "boot"],
            .targetMismatch(expected: "UDID-1", actual: nil)
        )

        for verb in ["create", "clone", "delete", "erase", "rename", "runtime", "list", "unknown"] {
            XCTAssertEqual(
                try LaneCommandPolicy.validate(
                    invocation: ["xcrun", "simctl", verb, "UDID-1"],
                    descriptor: descriptor
                ),
                .global,
                verb
            )
        }
    }

    func testAXeRequiresOneExactUDIDAndListIsGlobal() throws {
        for invocation in [
            ["axe", "tap", "--label", "Continue"],
            ["axe", "tap", "--udid", "OTHER"],
            ["axe", "tap", "--udid", "UDID-1", "--udid", "UDID-1"],
        ] {
            XCTAssertThrowsError(
                try LaneCommandPolicy.validate(invocation: invocation, descriptor: descriptor)
            ) {
                XCTAssertEqual($0 as? LaneServiceError, .unsupportedAXeTargeting)
            }
        }
        XCTAssertEqual(
            try LaneCommandPolicy.validate(
                invocation: ["axe", "list-simulators"],
                descriptor: descriptor
            ),
            .global
        )
    }

    func testNoDescriptorUsesLegacyGlobalScopeAndUnprotectedPassesThrough() throws {
        XCTAssertEqual(
            try LaneCommandPolicy.validate(
                invocation: ["xcrun", "simctl", "boot", "UDID-1"],
                descriptor: nil
            ),
            .global
        )
        XCTAssertEqual(
            try LaneCommandPolicy.validate(invocation: ["swift", "--version"], descriptor: descriptor),
            .passThrough
        )
    }

    private func assertError(
        _ invocation: [String],
        _ expected: LaneServiceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LaneCommandPolicy.validate(invocation: invocation, descriptor: descriptor),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? LaneServiceError, expected, file: file, line: line)
        }
    }
}
