import XCTest
@testable import SimLeaseCore

final class RuntimeCompatibilityTests: XCTestCase {
    func testOnlySameVersionIOSRuntimesOlderThanTheSDKAreStale() {
        let runtimes = [
            RuntimeCompatibility.Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", version: "27.2", build: "24B5089g"),
            RuntimeCompatibility.Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4", version: "27.2", build: "24B91011"),
            RuntimeCompatibility.Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", version: "27.0", build: "24A434"),
            RuntimeCompatibility.Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.watchOS-27-2", version: "27.2", build: "24S5091f"),
        ]
        XCTAssertEqual(
            RuntimeCompatibility.stale(sdkVersion: "27.2", sdkBuild: "24B5109a", runtimes: runtimes),
            [StaleRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", version: "27.2", build: "24B5089g", sdkBuild: "24B5109a")]
        )
        let updated = runtimes + [RuntimeCompatibility.Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", version: "27.2", build: "24B5109a")]
        XCTAssertTrue(RuntimeCompatibility.stale(sdkVersion: "27.2", sdkBuild: "24B5109a", runtimes: updated).isEmpty)
        XCTAssertTrue(RuntimeCompatibility.stale(sdkVersion: "27.2", sdkBuild: "unknown", runtimes: runtimes).isEmpty)
    }
}
