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

    func testLeadingSimulatorOptionsPreserveDeclaredTargetAdmission() throws {
        let cases: [[String]] = [
            ["launch", "--terminate-running-process", device, "com.example.app"],
            ["launch", "-w", "--console-pty", device, "com.example.app"],
            ["launch", "--wait-for-debugger", "--console", device, "com.example.app"],
            ["launch", "--stdout", "/tmp/x", device, "com.example.app"],
            ["launch", "--stderr", "/tmp/x", device, "com.example.app"],
            ["launch", "--stdout=/tmp/x", "--stderr=/tmp/y", device, "com.example.app"],
            ["launch", "-a", "arm64", "--checked-allocations", device, "com.example.app"],
            ["launch", "--arch", "arm64", device, "com.example.app"],
            ["launch", "--arch=arm64", device, "com.example.app"],
            ["spawn", "-w", "-s", device, "/bin/echo"],
            ["spawn", "--wait-for-debugger", "--standalone", device, "/bin/echo"],
            ["spawn", "-a", "arm64", "--checked-allocations", device, "/bin/echo"],
            ["spawn", "--arch", "arm64", device, "/bin/echo"],
            ["spawn", "--arch=arm64", device, "/bin/echo"],
            ["pbcopy", "-v", device],
            ["pbpaste", "-v", device],
        ]
        for prefix in [["simctl"], ["xcrun", "simctl"], ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "simctl"]] {
            for arguments in cases {
                let invocation = prefix + arguments
                XCTAssertNoThrow(try NativeClientAdmission.validate(invocation: invocation, deviceIDs: [device]), invocation.joined(separator: " "))
                XCTAssertEqual(SimulatorCommand.referencedDeviceIDs(in: invocation), [device], invocation.joined(separator: " "))
            }
        }
    }

    func testLeadingSimulatorOptionsCannotHideInvalidTargets() throws {
        let other = "22222222-2222-4222-8222-222222222222"
        let prefixes = [
            ["launch", "--terminate-running-process"],
            ["spawn", "-w", "--standalone"],
            ["pbcopy", "-v"],
            ["pbpaste", "-v"],
        ]
        var cases = [[String]]()
        for prefix in prefixes {
            for target in ["booted", "all", "Named iPhone", other] {
                cases.append(prefix + [target, device])
            }
            cases.append(prefix)
            cases.append([prefix[0], "--unknown-flag", device])
        }
        cases += [
            ["launch", "--stdout", device, "com.example.app"],
            ["launch", "--stderr", device, "com.example.app"],
            ["launch", "--stdout"],
            ["launch", "--stderr"],
            ["launch", "--arch", device, "com.example.app"],
            ["launch", "--console=anything", device, "com.example.app"],
            ["spawn", "-a", device, "/bin/echo"],
            ["spawn", "--arch", device, "/bin/echo"],
            ["spawn", "-a"],
            ["spawn", "--arch"],
            ["spawn", "--console", device, "/bin/echo"],
            ["pbcopy", "--stdout", "/tmp/x", device],
            ["pbpaste", "--console", device],
        ]
        for arguments in cases {
            XCTAssertThrowsError(try NativeClientAdmission.validate(invocation: ["xcrun", "simctl"] + arguments, deviceIDs: [device]), arguments.joined(separator: " "))
        }
    }
}
