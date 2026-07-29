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
}
