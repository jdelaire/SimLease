import XCTest
@testable import SimLeaseCLI

final class CommandParserTests: XCTestCase {
    func testParsesSupportedCommandsAndShimDispatch() throws {
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "--version"]),
            .version
        )
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "update"]),
            .update
        )
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "status", "--json"]),
            .status(json: true)
        )
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "name", "[SimLease] CLI"]),
            .name("[SimLease] CLI")
        )
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "hold", "--title", "Manual Xcode", "--project", "Set",
            ]),
            .hold(title: "Manual Xcode", project: "Set")
        )
        XCTAssertEqual(
            try CommandParser.parse(["xcrun", "simctl", "list"]),
            .shim(arguments: ["xcrun", "simctl", "list"])
        )
    }

    func testRejectsUnknownSimleaseCommand() {
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "unknown"]))
    }

    func testParsesDoctorAndWaitCommands() throws {
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "doctor"]),
            .doctor(json: false)
        )
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "doctor", "--json"]),
            .doctor(json: true)
        )
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "wait"]),
            .wait(timeout: 300, json: false)
        )
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "wait", "--timeout", "5", "--json",
            ]),
            .wait(timeout: 5, json: true)
        )
    }

    func testRejectsInvalidDoctorAndWaitShapes() {
        let invalid = [
            ["simlease", "doctor", "--timeout", "5"],
            ["simlease", "doctor", "--json", "--json"],
            ["simlease", "wait", "--timeout"],
            ["simlease", "wait", "--timeout", "0"],
            ["simlease", "wait", "--timeout", "-3"],
            ["simlease", "wait", "--timeout", "soon"],
            ["simlease", "wait", "--timeout", "5", "--timeout", "6"],
            ["simlease", "wait", "--json", "--json"],
        ]

        for arguments in invalid {
            XCTAssertThrowsError(try CommandParser.parse(arguments))
        }
    }

    func testParsesCleanupCommands() throws {
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "clean", "plan"]),
            .cleanPlan(json: false)
        )
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "clean", "plan", "--json"]),
            .cleanPlan(json: true)
        )
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "clean", "apply", "ABC123",
                "--target", "DEVICE-1",
                "--target", "archive:/tmp/App.xcarchive",
                "--json",
            ]),
            .cleanApply(
                id: "ABC123",
                targetIDs: ["DEVICE-1", "archive:/tmp/App.xcarchive"],
                json: true
            )
        )
    }

    func testRejectsUnsafeCleanupShapes() {
        let invalid = [
            ["simlease", "clean"],
            ["simlease", "clean", "plan", "--apply"],
            ["simlease", "clean", "apply"],
            ["simlease", "clean", "apply", "ABC123"],
            ["simlease", "clean", "apply", "ABC123", "--yes"],
            ["simlease", "clean", "apply", "ABC123", "--target"],
            ["simlease", "clean", "apply", "ABC123", "--target", "--json"],
            ["simlease", "clean", "apply", "device-uuid"],
        ]

        for arguments in invalid {
            XCTAssertThrowsError(try CommandParser.parse(arguments))
        }
    }

    func testParsesLaneCommands() throws {
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "lane", "acquire",
                "--project", "ExplorerDex",
                "--device-type", "iPhone 17 Pro",
                "--runtime", "latest",
                "--json",
            ]),
            .laneAcquire(
                project: "ExplorerDex",
                deviceType: "iPhone 17 Pro",
                runtime: "latest",
                json: true
            )
        )
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "lane", "status", "--json"]),
            .laneStatus(json: true)
        )
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "lane", "config", "--max-active", "2", "--json",
            ]),
            .laneConfig(maxActive: 2, json: true)
        )
        XCTAssertEqual(
            try CommandParser.parse(["simlease", "lane", "release"]),
            .laneRelease(json: false)
        )
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "lane", "recover", "plan", "lane-1", "--json",
            ]),
            .laneRecoverPlan(laneID: "lane-1", json: true)
        )
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "lane", "recover", "apply", "ABC123",
                "--lane", "lane-1", "--json",
            ]),
            .laneRecoverApply(planID: "ABC123", laneID: "lane-1", json: true)
        )
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "lane", "dispose", "plan", "UDID-1",
            ]),
            .laneDisposePlan(udid: "UDID-1", json: false)
        )
        XCTAssertEqual(
            try CommandParser.parse([
                "simlease", "lane", "dispose", "apply", "ABC123",
                "--target", "UDID-1",
            ]),
            .laneDisposeApply(planID: "ABC123", udid: "UDID-1", json: false)
        )
    }

    func testRejectsUnsafeLaneShapes() {
        let invalid = [
            ["simlease", "lane"],
            ["simlease", "lane", "acquire", "--project", "App"],
            ["simlease", "lane", "acquire", "--project", "App", "--project", "Other", "--device-type", "Phone", "--runtime", "latest"],
            ["simlease", "lane", "acquire", "--project", "App", "--device-type", "Phone", "--runtime", "latest", "--json", "--json"],
            ["simlease", "lane", "acquire", "--project", "--device-type", "Phone", "--runtime", "latest"],
            ["simlease", "lane", "config", "--max-active", "0"],
            ["simlease", "lane", "config", "--max-active", "2", "--max-active", "3"],
            ["simlease", "lane", "status", "--verbose"],
            ["simlease", "lane", "release", "extra"],
            ["simlease", "lane", "recover"],
            ["simlease", "lane", "recover", "plan"],
            ["simlease", "lane", "recover", "apply", "bad", "--lane", "lane-1"],
            ["simlease", "lane", "recover", "apply", "ABC123", "--target", "lane-1"],
            ["simlease", "lane", "dispose", "plan", "--json"],
            ["simlease", "lane", "dispose", "apply", "ABC123", "--target"],
            ["simlease", "lane", "dispose", "apply", "ABC123", "--target", "UDID-1", "--target", "UDID-2"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try CommandParser.parse(arguments), "\(arguments)")
        }
    }
}
