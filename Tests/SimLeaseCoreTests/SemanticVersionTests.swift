import XCTest
@testable import SimLeaseCore

final class SemanticVersionTests: XCTestCase {
    func testParsesCanonicalAndTagVersions() {
        XCTAssertEqual(SemanticVersion("0.1.0")?.description, "0.1.0")
        XCTAssertEqual(SemanticVersion("v0.1.0")?.description, "0.1.0")
    }

    func testComparesMajorMinorAndPatch() {
        XCTAssertLessThan(SemanticVersion("0.1.0")!, SemanticVersion("0.1.1")!)
        XCTAssertLessThan(SemanticVersion("0.1.9")!, SemanticVersion("0.2.0")!)
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
    }

    func testRejectsUnsupportedVersions() {
        for value in ["1.0", "1.0.0-beta", "-1.0.0", "one.0.0", "1.0.0.0"] {
            XCTAssertNil(SemanticVersion(value), value)
        }
    }
}
