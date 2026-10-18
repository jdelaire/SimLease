import XCTest
@testable import SimLeaseCLI

final class CommandParserTests: XCTestCase {
    func testParsesTaskScopeAndRejectsAmbiguousDeviceSelection() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(try CommandParser.parse([
            "simlease", "run", "--device", id, "--keep-running", "--", "/bin/true",
        ]), .run(deviceIDs: [id], keepRunning: true, command: ["/bin/true"]))
        XCTAssertEqual(try CommandParser.parse(["simlease", "recover"]), .recover)
        XCTAssertEqual(try CommandParser.parse([
            "simlease", "hold", "--title", "UI verification", "--project", "App", "--device", id,
        ]), .hold(title: "UI verification", project: "App", deviceIDs: [id], keepRunning: false))
        for arguments in [
            ["simlease", "run", "--device", "booted", "--", "/bin/true"],
            ["simlease", "run", "--device", "../bad", "--", "/bin/true"],
            ["simlease", "run", "--keep-running", "--keep-running", "--", "/bin/true"],
            ["simlease", "run", "--"],
        ] {
            XCTAssertThrowsError(try CommandParser.parse(arguments))
        }
    }

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
}
