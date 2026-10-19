import XCTest
@testable import SimLeaseCLI

final class CommandParserTests: XCTestCase {
    func testDisposableCreationRequiresExplicitOptInAndRecoveryRequiresUUID() throws {
        let type = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
        let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
        let create = ["simlease", "device", "create", "--name", "Disposable", "--type", type, "--runtime", runtime]
        XCTAssertThrowsError(try CommandParser.parse(create))
        XCTAssertEqual(try CommandParser.parse(create + ["--disposable"]), .deviceCreate(name: "Disposable", deviceType: type, runtime: runtime))
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(try CommandParser.parse(["simlease", "device", "repair", "--device", id, "--settled", "--acknowledge-crashes", "--json"]), .deviceRepair(id, settled: true, acknowledgeCrashes: true))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "device", "repair", "--device", "booted"]))
        XCTAssertThrowsError(try CommandParser.parse(create + ["--disposable", "--disposable"]))
        XCTAssertEqual(try CommandParser.parse(["simlease", "device", "recover", "--settled"]), .deviceRecover)
    }
    func testNativeBindingsRequireExplicitValidPIDs() throws {
        let base = ["simlease", "session", "begin", "--device", "11111111-1111-4111-8111-111111111111", "--title", "UI", "--project", "App"]
        XCTAssertEqual(try CommandParser.parse(base + ["--client-pid", "123"]), .sessionBegin(title: "UI", project: "App", deviceIDs: ["11111111-1111-4111-8111-111111111111"], clientPIDs: [123]))
        for pid in ["0", "1", "-1", "invalid"] {
            XCTAssertThrowsError(try CommandParser.parse(base + ["--client-pid", pid]))
        }
    }
    func testNativeSessionNeedsDeclaredDevicesAndExplicitSettlement() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(try CommandParser.parse(["simlease", "session", "begin", "--device", id, "--title", "UI", "--project", "App"]), .sessionBegin(title: "UI", project: "App", deviceIDs: [id]))
        XCTAssertEqual(try CommandParser.parse(["simlease", "session", "finish", id, "--settled"]), .sessionFinish(id))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "session", "begin", "--title", "UI", "--project", "App"]))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "session", "finish", id]))
    }

    func testStatusAuditIsExplicitAndFlagsCanAppearInEitherOrder() throws {
        XCTAssertEqual(try CommandParser.parse(["simlease", "status", "--audit", "--json"]), .status(json: true, audit: true))
        XCTAssertEqual(try CommandParser.parse(["simlease", "status", "--json", "--audit"]), .status(json: true, audit: true))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "status", "--audit", "--audit"]))
        XCTAssertEqual(try CommandParser.parse(["simlease", "status", "--devices", "--json", "--audit"]), .status(json: true, audit: true, devices: true))
        let a = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", b = "22222222-2222-4222-8222-222222222222"
        XCTAssertEqual(try CommandParser.parse(["simlease", "device", "shutdown", "--device", a.lowercased(), "--device", b]), .deviceShutdown([a, b]))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "device", "shutdown", "--device", a, "--device", a.lowercased()]))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "device", "shutdown"]))
        XCTAssertEqual(try CommandParser.parse(["simlease", "device", "reap"]), .deviceReap)
        XCTAssertEqual(try CommandParser.parse(["simlease", "device", "acknowledge", "--device", a.lowercased()]), .deviceAcknowledge(a))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "device", "acknowledge"]))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "device", "reap", "--device", a]))
        XCTAssertThrowsError(try CommandParser.parse(["simlease", "device", "shutdown", "--device", "booted"]))
    }

    func testParsesTaskScopeAndRejectsAmbiguousDeviceSelection() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(try CommandParser.parse([
            "simlease", "run", "--device", id, "--keep-running", "--", "/bin/true",
        ]), .run(deviceIDs: [id], keepRunning: true, command: ["/bin/true"]))
        XCTAssertEqual(try CommandParser.parse([
            "simlease", "run", "--device", id, "--keep-warm", "--", "/bin/true",
        ]), .run(deviceIDs: [id], keepRunning: false, keepWarm: true, command: ["/bin/true"]))
        XCTAssertEqual(try CommandParser.parse(["simlease", "recover"]), .recover)
        XCTAssertEqual(try CommandParser.parse([
            "simlease", "hold", "--title", "UI verification", "--project", "App", "--device", id,
        ]), .hold(title: "UI verification", project: "App", deviceIDs: [id], keepRunning: false))
        for arguments in [
            ["simlease", "run", "--device", "booted", "--", "/bin/true"],
            ["simlease", "run", "--device", "../bad", "--", "/bin/true"],
            ["simlease", "run", "--keep-running", "--keep-running", "--", "/bin/true"],
            ["simlease", "run", "--device", id, "--keep-running", "--keep-warm", "--", "/bin/true"],
            ["simlease", "run", "--device", id, "--keep-warm", "--keep-running", "--", "/bin/true"],
            ["simlease", "run", "--device", id, "--keep-warm", "--keep-warm", "--", "/bin/true"],
            ["simlease", "run", "--keep-warm", "--", "/bin/true"],
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
