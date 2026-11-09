import XCTest
@testable import SimLeaseCore

final class UpdateSignalTests: XCTestCase {
    func testUpdateRequestExpiresBeforeCLIFallsBack() {
        let sent = Date(timeIntervalSince1970: 1_000)
        let token = UpdateSignal.requestToken(id: "A", sentAt: sent)

        XCTAssertTrue(UpdateSignal.isFresh(token, now: sent.addingTimeInterval(3.9)))
        XCTAssertFalse(UpdateSignal.isFresh(token, now: sent.addingTimeInterval(UpdateSignal.requestLifetime)))
        XCTAssertFalse(UpdateSignal.isFresh("A", now: sent))
    }
}
