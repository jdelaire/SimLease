import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class ProcessIdentityInspectorTests: XCTestCase {
    func testCurrentProcessMatchesWaiterCreatedNow() {
        let inspector = SystemProcessIdentityInspector()

        let state = inspector.identityState(
            pid: getpid(),
            waitingSince: Date()
        )

        XCTAssertEqual(state, .matching)
    }

    func testCurrentPIDIsReusedForWaiterOlderThanProcess() {
        let inspector = SystemProcessIdentityInspector()

        let state = inspector.identityState(
            pid: getpid(),
            waitingSince: .distantPast
        )

        XCTAssertEqual(state, .reused)
    }

    func testImpossiblePIDIsMissing() {
        let inspector = SystemProcessIdentityInspector()

        let state = inspector.identityState(
            pid: Int32.max,
            waitingSince: Date()
        )

        XCTAssertEqual(state, .missing)
    }
}
