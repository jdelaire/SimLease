import XCTest
@testable import SimLeaseCore

final class SimulatorCommandTests: XCTestCase {
    func testRecognizesExplicitDeviceReferencesInAutomationCommands() {
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: ["xcrun", "simctl", "boot", id]), [id])
        XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: ["agent-device", "--udid", id, "snapshot"]), [id])
        XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: ["agent-device", "--device=\(id)", "snapshot"]), [id])
        XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: ["/bin/echo", id]), [])
    }

    func testInfersOnlyExactSimulatorDestinationIDs() {
        XCTAssertEqual(SimulatorCommand.deviceIDs(in: [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "test",
            "-destination", "platform=iOS Simulator,id=11111111-1111-4111-8111-111111111111",
        ]), ["11111111-1111-4111-8111-111111111111"])
        XCTAssertEqual(SimulatorCommand.deviceIDs(in: [
            "xcodebuild", "test", "-destination", "platform=iOS Simulator,name=iPhone 18 Pro",
        ]), [])
        XCTAssertEqual(SimulatorCommand.deviceIDs(in: ["/bin/sh", "-c", "xcodebuild test"]), [])
        XCTAssertEqual(SimulatorCommand.deviceIDs(in: [
            "xcodebuild", "test", "-destination", "platform=macOS,id=11111111-1111-4111-8111-111111111111",
        ]), [])
    }

    func testManagedTestCommandCannotEnableParallelSimulatorClones() {
        XCTAssertEqual(SimulatorCommand.argumentsForManagedTask(
            executable: "xcodebuild", arguments: ["test", "-destination", "platform=iOS Simulator,name=iPhone 18 Pro"], hasDevices: false
        ), ["test", "-destination", "platform=iOS Simulator,name=iPhone 18 Pro", "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1"])
        XCTAssertEqual(SimulatorCommand.argumentsForManagedTask(
            executable: "xcodebuild",
            arguments: ["test", "-parallel-testing-enabled", "YES", "-maximum-concurrent-test-simulator-destinations", "4"],
            hasDevices: true
        ), ["test", "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1"])
        XCTAssertEqual(SimulatorCommand.argumentsForManagedTask(
            executable: "xcrun", arguments: ["swift", "test"], hasDevices: true
        ), ["swift", "test"])
        XCTAssertEqual(SimulatorCommand.argumentsForManagedTask(
            executable: "xcrun", arguments: ["swift", "test", "xcodebuild"], hasDevices: true
        ), ["swift", "test", "xcodebuild"])
    }

    func testSimulatorReferencesOnlyUseTheActualDevicePosition() {
        let device = "11111111-1111-4111-8111-111111111111"
        let other = "22222222-2222-4222-8222-222222222222"
        for arguments in [
            ["launch", "--stdout", other, device, "com.example.app", other],
            ["spawn", "--arch", other, device, "/bin/echo", other],
            ["pbcopy", "-v", device, other],
            ["pbpaste", "-v", device, other],
            ["io", device, "screenshot", "--display", other, "/tmp/x"],
        ] {
            XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: ["xcrun", "simctl"] + arguments), [device], arguments.joined(separator: " "))
        }
        for action in ["boot", "bootstatus", "shutdown", "io", "getenv", "get_app_container", "get_app_info", "listapps", "launch", "terminate", "spawn", "install", "uninstall", "ui", "status_bar", "keychain", "push", "privacy", "pbcopy", "pbpaste", "openurl", "addmedia"] {
            for target in ["booted", "all", "Named iPhone", "--unknown-flag"] {
                let arguments = ["simctl", action, target, device]
                XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: arguments), [], arguments.joined(separator: " "))
            }
            XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: ["simctl", action]), [])
        }
        for arguments in [
            ["launch", "--stdout", device, "com.example.app"],
            ["launch", "--stderr", device, "com.example.app"],
            ["launch", "--stdout", device],
            ["spawn", "--arch", device, "/bin/echo"],
            ["spawn", "-a", device],
        ] {
            XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: ["simctl"] + arguments), [], arguments.joined(separator: " "))
        }
        XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: ["simctl", "clone", device, other]), [device, other])
    }
}
