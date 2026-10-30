import XCTest
@testable import SimLeaseCore

final class SimulatorServiceCatalogTests: XCTestCase {
    func testDesiredExcludesProtectedAndKeepsSharedLabels() throws {
        let all = try SimulatorServiceCatalog.desired(keep: [])
        XCTAssertTrue(all.contains("com.apple.PosterBoard"))
        XCTAssertTrue(all.contains("com.apple.navd"))
        for label in ["com.apple.SpringBoard", "com.apple.backboardd", "com.apple.assistantd"] { XCTAssertFalse(all.contains(label)) }
        let widgets = try SimulatorServiceCatalog.desired(keep: ["widgets"])
        XCTAssertFalse(widgets.contains("com.apple.navd"))
        XCTAssertFalse(widgets.contains("com.apple.PosterBoard"))
        XCTAssertTrue(SimulatorServiceCatalog.categories.first { $0.id == "connectivity" }?.labels.contains("com.apple.navd") == true)
        XCTAssertThrowsError(try SimulatorServiceCatalog.desired(keep: ["nope"])) {
            XCTAssertEqual($0 as? SimulatorServiceCatalogError, .unknownCategory("nope"))
        }
    }

    func testDeltaTouchesManagedLabelsOnly() {
        let current: Set = ["com.apple.chronod", "com.apple.assistantd", "com.example.custom"]
        let desired: Set = ["com.apple.PosterBoard", "com.apple.chronod", "com.example.ignored"]
        let delta = SimulatorServiceCatalog.delta(current: current, desired: desired)
        XCTAssertEqual(delta.disable, ["com.apple.PosterBoard"])
        XCTAssertEqual(delta.enable, ["com.apple.assistantd"])
    }

    func testParseDisabledAcceptsBothValueForms() {
        let output = "disabled services = {\n\t\"com.apple.a\" => disabled\n\t\"com.apple.b\" => enabled\n\t\"com.apple.c\" => true\n\t\"com.apple.d\" => false\n}\n"
        XCTAssertEqual(SimulatorServiceCatalog.parseDisabled(output), ["com.apple.a", "com.apple.c"])
    }

    func testOnlyIOS185AndNewerPersistOverrides() {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        XCTAssertTrue(SimulatorServiceCatalog.supportsPersistentOverrides(runtime: prefix + "iOS-18-5"))
        XCTAssertTrue(SimulatorServiceCatalog.supportsPersistentOverrides(runtime: prefix + "iOS-27-2"))
        XCTAssertTrue(SimulatorServiceCatalog.supportsPersistentOverrides(runtime: prefix + "iOS-19-0"))
        XCTAssertFalse(SimulatorServiceCatalog.supportsPersistentOverrides(runtime: prefix + "iOS-18-4"))
        XCTAssertFalse(SimulatorServiceCatalog.supportsPersistentOverrides(runtime: prefix + "iOS-17-5"))
        XCTAssertFalse(SimulatorServiceCatalog.supportsPersistentOverrides(runtime: prefix + "watchOS-11-5"))
        XCTAssertFalse(SimulatorServiceCatalog.supportsPersistentOverrides(runtime: prefix + "iOS"))
    }
}
