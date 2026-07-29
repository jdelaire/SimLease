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
                "simlease", "clean", "apply", "ABC123", "--json",
            ]),
            .cleanApply(id: "ABC123", json: true)
        )
    }

    func testRejectsUnsafeCleanupShapes() {
        let invalid = [
            ["simlease", "clean"],
            ["simlease", "clean", "plan", "--apply"],
            ["simlease", "clean", "apply"],
            ["simlease", "clean", "apply", "ABC123", "--yes"],
            ["simlease", "clean", "apply", "device-uuid"],
        ]

        for arguments in invalid {
            XCTAssertThrowsError(try CommandParser.parse(arguments))
        }
    }
}
