import XCTest
@testable import SimLeaseCore

final class ActiveUseProviderTests: XCTestCase {
    func testExtractsOnlyPathsFromBuildAndTestCommands() {
        let output = """
        /usr/bin/xcodebuild -scheme App -derivedDataPath /tmp/AppDerived test
        /usr/bin/swift test --scratch-path /tmp/App.build
        /usr/bin/other --path /tmp/Ignore
        """

        XCTAssertEqual(
            ProcessActiveUseProvider.paths(from: output),
            ["/tmp/App.build", "/tmp/AppDerived"]
        )
    }

    func testKeepsQuotedPathsWithSpacesIntact() {
        let output = """
        /usr/bin/xcodebuild -scheme App -derivedDataPath "/tmp/My App/DerivedData" test
        /usr/bin/xcodebuild -scheme App -resultBundlePath '/tmp/My App/Results.xcresult' test
        """

        XCTAssertEqual(
            ProcessActiveUseProvider.paths(from: output),
            ["/tmp/My App/DerivedData", "/tmp/My App/Results.xcresult"]
        )
    }

    func testMatchesDeviceSupportPathWithSpaces() {
        let output = """
        /usr/bin/xcodebuild -scheme App test "/Users/me/Library/Developer/Xcode/iOS DeviceSupport/17.0/Symbols"
        """

        XCTAssertEqual(
            ProcessActiveUseProvider.paths(from: output),
            ["/Users/me/Library/Developer/Xcode/iOS DeviceSupport/17.0/Symbols"]
        )
    }
}
