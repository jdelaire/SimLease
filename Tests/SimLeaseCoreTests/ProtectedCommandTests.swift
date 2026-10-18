import XCTest
@testable import SimLeaseCore

final class ProtectedCommandTests: XCTestCase {
    func testClassifiesProtectedAndPassThroughInvocations() {
        let cases: [([String], Bool)] = [
            (["xcodebuild", "test"], true),
            (["xcodebuild", "test-without-building"], true),
            (["xcodebuild", "build-for-testing"], true),
            (["xcodebuild", "build", "-destination", "id=11111111-1111-4111-8111-111111111111"], true),
            (["xcodebuild", "build", "-sdk", "iphonesimulator"], true),
            (["xcodebuild", "-destination", "platform=iOS Simulator,name=iPhone 17", "build"], true),
            (["xcodebuild", "-destination=platform=macOS", "build"], false),
            (["xcodebuild", "-destination", "generic/platform=iOS", "build"], false),
            (["xcrun", "simctl", "list"], false),
            (["xcrun", "simctl", "--set", "/tmp/devices", "list"], false),
            (["xcrun", "simctl", "boot", "ABC", "list"], true),
            (["xcrun", "simctl", "spawn", "ABC", "launchctl", "-f"], true),
            (["xcrun", "simctl", "--unknown", "list"], true),
            (["xcrun", "--find", "simctl"], false),
            (["xcrun", "--sdk", "iphonesimulator", "simctl", "boot", "ABC"], true),
            (["xcrun", "swift", "--version"], false),
            (["xcrun", "xcodebuild", "test"], true),
            (["xcrun", "--sdk", "iphonesimulator", "xcodebuild", "test"], true),
            (["xcrun", "--find", "xcodebuild"], false),
            (["xcrun", "--log", "xcodebuild", "test"], true),
            (["agent-device", "open", "com.example.App"], true),
            (["agent-device", "--session", "qa", "snapshot", "-i"], true),
            (["agent-device", "--help"], false),
            (["agent-device", "daemon", "start"], false),
            (["agent-device", "--session", "qa", "daemon", "start"], false),
            (["agent-device", "--session", "daemon", "snapshot"], true),
            (["agent-device", "--session", "capabilities", "snapshot"], true),
            (["axe", "tap", "--id", "Done"], true),
        ]

        for (arguments, expected) in cases {
            XCTAssertEqual(
                ProtectedCommand.classify(invocation: arguments).requiresLease,
                expected,
                "\(arguments)"
            )
        }
    }
}
