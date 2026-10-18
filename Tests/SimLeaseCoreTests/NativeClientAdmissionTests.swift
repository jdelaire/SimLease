import Foundation
import XCTest
@testable import SimLeaseCore

final class NativeClientAdmissionTests: XCTestCase {
    let device = "11111111-1111-4111-8111-111111111111"

    func testRunnerBuildsRequireEveryDestinationToBeExplicitAndInScope() throws {
        for destination in ["id=\(device)", "platform=iOS Simulator,id=\(device)"] {
            XCTAssertNoThrow(try NativeClientAdmission.validate(invocation: ["xcodebuild", "build-for-testing", "-destination", destination], deviceIDs: [device]))
            XCTAssertNoThrow(try NativeClientAdmission.validate(invocation: ["xcrun", "xcodebuild", "test-without-building", "-destination", destination], deviceIDs: [device]))
        }
        for arguments in [
            ["test", "-destination", "id=\(device)", "-destination", "platform=iOS Simulator,name=iPhone"],
            ["test", "-destination", "id=\(device),id=\(device)"],
            ["test", "-destination", "platform=macOS,id=\(device)"],
            ["test", "-sdk", "iphoneos", "-destination", "id=\(device)"],
            ["test", "-destination", "id=\(device)", "-DVTSimulatorSetLocation=/tmp/other"],
            ["test", "-destination"],
            ["test", "-destination="],
            ["test", "-destination", "id=\(device),broken"],
            ["test", "-list"],
            ["-runFirstLaunch", "-list"],
            ["-downloadPlatform", "iOS", "-list"],
            ["-downloadPlatform", "iOS", "-destination", "id=\(device)"],
        ] {
            XCTAssertThrowsError(try NativeClientAdmission.validate(invocation: ["xcodebuild"] + arguments, deviceIDs: [device]))
        }
        XCTAssertNoThrow(try NativeClientAdmission.validate(invocation: ["xcodebuild", "-version"], deviceIDs: [device]))
        XCTAssertNoThrow(try NativeClientAdmission.validate(invocation: ["xcodebuild", "-showBuildSettings", "-sdk", "iphonesimulator"], deviceIDs: [device]))
    }

    func testOnlyExplicitPositionalSimulatorTargetsAreAdmitted() throws {
        for action in ["boot", "bootstatus", "shutdown", "spawn", "io", "launch", "install", "terminate", "ui"] {
            XCTAssertNoThrow(try NativeClientAdmission.validate(invocation: ["xcrun", "simctl", action, device], deviceIDs: [device]))
        }
        XCTAssertNoThrow(try NativeClientAdmission.validate(invocation: ["xcrun", "simctl", "list", "devices", "--json"], deviceIDs: [device]))
        for arguments in [
            ["spawn", "booted", "/bin/echo", device],
            ["shutdown", "all", device],
            ["boot", "Named iPhone", device],
            ["boot", "22222222-2222-4222-8222-222222222222"],
            ["runtime", "delete", device],
            ["--set", "/tmp/other", "boot", device],
            ["create", device],
        ] {
            XCTAssertThrowsError(try NativeClientAdmission.validate(invocation: ["xcrun", "simctl"] + arguments, deviceIDs: [device]))
        }
    }
}
