import Foundation
import XCTest
@testable import SimLeaseCore

final class CrashLoopTests: XCTestCase {
    let device = "11111111-1111-4111-8111-111111111111"
    let other = "22222222-2222-4222-8222-222222222222"

    func testReportUsesEventTimeAndStableBuildSignature() throws {
        let first = try XCTUnwrap(SimulatorCrashReport.parse(report(incident: "one")))
        let duplicateBuild = try XCTUnwrap(SimulatorCrashReport.parse(report(incident: "two", imageIndex: 1)))
        let changedBuild = try XCTUnwrap(SimulatorCrashReport.parse(report(incident: "three", build: "different")))
        XCTAssertEqual(first.deviceID, device)
        XCTAssertEqual(first.occurredAt.timeIntervalSince1970, 1_792_371_600.25, accuracy: 0.001)
        XCTAssertEqual(first.signature, duplicateBuild.signature)
        XCTAssertNotEqual(first.signature, changedBuild.signature)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(first), as: UTF8.self).contains("/Users/"))
    }

    func testUUIDDisagreementAndMissingLaunchTimeCannotAuthorizeCancellation() throws {
        XCTAssertNil(SimulatorCrashReport.parse(try report(incident: "one", coalition: other)))
        XCTAssertNil(SimulatorCrashReport.parse(try report(incident: "two", launch: "unknown")))
    }

    func testSameFaultUnderDifferentTestCallersStillCountsAsOneSignature() throws {
        let base = try report(incident: "one")
        let newline = try XCTUnwrap(base.firstIndex(of: 10))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: base.suffix(from: base.index(after: newline))) as? [String: Any])
        object["threads"] = [["frames": [["imageIndex": 0, "symbol": "static Date.<= infix(_:_:)"], ["imageIndex": 0, "symbol": "unrelated test caller"]]]]
        let varied = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(SimulatorCrashReport.parse(base)?.signature, SimulatorCrashReport.parse(varied)?.signature)
    }

    func testTwoUniqueCrashesAcrossScopesPersistBlockAndAttributeNewestScope() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "first", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        try fixture.store.endScope(id: "first", endedAt: Date(timeIntervalSince1970: 105))
        try fixture.store.beginScope(id: "second", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 106))
        let one = event("one", at: 100, launch: 95)
        XCTAssertEqual(try fixture.store.ingest([one, one], now: Date(timeIntervalSince1970: 115)), [])
        let triggers = try fixture.store.ingest([event("two", at: 110, launch: 107)], now: Date(timeIntervalSince1970: 115))
        XCTAssertEqual(triggers.first?.scopeID, "second")
        XCTAssertEqual(triggers.first?.deviceID, device)
        XCTAssertThrowsError(try CrashLoopStore(paths: fixture.paths).requireHealthy([device]))
        XCTAssertNoThrow(try fixture.store.requireHealthy([other]))
    }

    func testDelayedReportBlocksFutureAdmissionWithoutAttributingCurrentScope() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "old", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        try fixture.store.endScope(id: "old", endedAt: Date(timeIntervalSince1970: 115))
        try fixture.store.beginScope(id: "new", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 200))
        let triggers = try fixture.store.ingest([event("one", at: 100, launch: 95), event("two", at: 110, launch: 105)], now: Date(timeIntervalSince1970: 210))
        XCTAssertEqual(triggers.first?.scopeID, "old")
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testLateOldCrashJoiningOneCurrentCrashCannotCancelCurrentScope() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "old", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        try fixture.store.endScope(id: "old", endedAt: Date(timeIntervalSince1970: 105))
        try fixture.store.beginScope(id: "new", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try fixture.store.ingest([event("new", at: 210, launch: 205)], now: Date(timeIntervalSince1970: 211)), [])
        let triggers = try fixture.store.ingest([event("old", at: 100, launch: 95)], now: Date(timeIntervalSince1970: 215))
        XCTAssertEqual(triggers.first?.scopeID, "old")
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testSameBatchOldAndCurrentCrashesStillCancelContributingCurrentScope() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "old", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        try fixture.store.endScope(id: "old", endedAt: Date(timeIntervalSince1970: 105))
        try fixture.store.beginScope(id: "new", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 200))
        let triggers = try fixture.store.ingest([event("old", at: 100, launch: 95), event("new", at: 210, launch: 205)], now: Date(timeIntervalSince1970: 215))
        XCTAssertTrue(triggers.contains { $0.scopeID == "new" })
    }

    func testBorrowedAndOldProcessCrashesDoNotTripOwnedScope() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try fixture.store.ingest([
            event("one", at: 110, launch: 90), event("two", at: 115, launch: 90),
            event("three", at: 110, launch: 105, deviceID: other), event("four", at: 115, launch: 105, deviceID: other),
        ], now: Date(timeIntervalSince1970: 120)), [])
        XCTAssertNoThrow(try fixture.store.requireHealthy([device, other]))
    }

    func testAcknowledgmentPreservesEvidenceAndOnlyPermitsDeliberateRetry() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        _ = try fixture.store.ingest([event("one", at: 100, launch: 95), event("two", at: 110, launch: 105)], now: Date(timeIntervalSince1970: 115))
        try fixture.store.acknowledge(deviceID: device, at: Date(timeIntervalSince1970: 120))
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertEqual(try fixture.store.read().incidents.count, 2)
        XCTAssertEqual(try fixture.store.ingest([event("late", at: 112, launch: 105)], now: Date(timeIntervalSince1970: 130)), [])
    }

    private func event(_ id: String, at: TimeInterval, launch: TimeInterval, deviceID: String? = nil) -> SimulatorCrashReport {
        SimulatorCrashReport(incidentID: id, deviceID: deviceID ?? device, occurredAt: Date(timeIntervalSince1970: at), launchedAt: Date(timeIntervalSince1970: launch), signature: "same-build-and-stack", processName: "App")
    }

    private func report(incident: String, build: String = "build", imageIndex: Int = 0, coalition: String? = nil, launch: String = "2026-10-19 07:59:59.1234 +0700") throws -> Data {
        var images: [[String: String]] = [["name": "App", "uuid": build]]
        if imageIndex == 1 { images.insert(["name": "unrelated", "uuid": "other"], at: 0) }
        let body: [String: Any] = [
            "incident": incident, "procName": "App", "captureTime": "2026-10-19 08:00:00.2500 +0700", "procLaunch": launch,
            "procPath": "/Users/USER/Library/Developer/CoreSimulator/Devices/\(device)/data/Containers/Bundle/Application/id/App.app/App",
            "coalitionName": "com.apple.CoreSimulator.SimDevice.\(coalition ?? device)",
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "bundleInfo": ["CFBundleIdentifier": "test.app"], "faultingThread": 0,
            "threads": [["frames": [["imageIndex": imageIndex], ["imageIndex": imageIndex, "symbol": "static Date.<= infix(_:_:)"]]]], "usedImages": images,
        ]
        return Data("{\"bug_type\":\"309\"}\n".utf8) + (try JSONSerialization.data(withJSONObject: body))
    }
}

private struct CrashFixture {
    let paths: LeasePaths
    let store: CrashLoopStore
    init() throws {
        paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try MetadataStore(paths: paths)
        store = CrashLoopStore(paths: paths)
    }
    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}
