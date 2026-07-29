import XCTest
@testable import SimLeaseCore

final class ProtectedCommandTests: XCTestCase {
    func testClassifiesProtectedAndPassThroughInvocations() {
        let cases: [([String], Bool)] = [
            (["xcodebuild", "test"], true),
            (["xcodebuild", "test-without-building"], true),
            (["xcodebuild", "build-for-testing"], true),
            (["xcodebuild", "-destination", "platform=iOS Simulator,name=iPhone 17", "build"], true),
            (["xcodebuild", "-destination=platform=macOS", "build"], false),
            (["xcodebuild", "-destination", "generic/platform=iOS", "build"], false),
            (["xcrun", "simctl", "list"], true),
            (["xcrun", "--sdk", "iphonesimulator", "simctl", "boot", "ABC"], true),
            (["xcrun", "swift", "--version"], false),
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
