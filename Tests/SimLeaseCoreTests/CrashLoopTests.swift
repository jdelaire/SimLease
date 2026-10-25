import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class CrashLoopTests: XCTestCase {
    let device = "11111111-1111-4111-8111-111111111111"
    let other = "22222222-2222-4222-8222-222222222222"

    func testAppleBackgroundServiceCrashesNeverBlockOrCancelAppWork() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let first = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "procName": "intelligencetasksd", "procPath": "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd",
            "bundleInfo": ["CFBundleIdentifier": "com.apple.intelligencetasksd"],
        ])))
        let secondData = try runtimeReport(changes: [
            "incident": "second", "procName": "intelligencetasksd", "procPath": "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd",
            "bundleInfo": ["CFBundleIdentifier": "com.apple.intelligencetasksd"],
        ])
        let second = try XCTUnwrap(SimulatorCrashReport.parse(secondData))
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: first.launchedAt.addingTimeInterval(-1))
        XCTAssertTrue(try fixture.store.ingest([first, second], now: first.occurredAt.addingTimeInterval(1)).isEmpty)
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
        XCTAssertEqual(try fixture.store.read().incidents.count, 2)
    }

    func testEvidenceCompletenessRequiresDrainedReadableReportDirectory() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<65 { try Data(#"{"procName":"Host","procPath":"/usr/bin/host"}"#.utf8).write(to: directory.appendingPathComponent("\(index).ips")) }
        let source = CrashReportSource(directory: directory, paths: fixture.paths)
        _ = try source.inspect(store: fixture.store)
        XCTAssertFalse(source.evidenceComplete)
        _ = try source.inspect(store: fixture.store)
        XCTAssertTrue(source.evidenceComplete)
        let oversized = directory.appendingPathComponent("large.ips")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let file = try FileHandle(forWritingTo: oversized)
        try file.truncate(atOffset: 5_000_001)
        try file.close()
        _ = try source.inspect(store: fixture.store)
        XCTAssertFalse(source.evidenceComplete)
        let missing = CrashReportSource(directory: directory.appendingPathComponent("missing"), paths: fixture.paths)
        _ = try missing.inspect(store: fixture.store)
        XCTAssertFalse(missing.evidenceComplete)
    }

    func testMalformedReportsRemainPendingUntilReadableSimulatorEvidenceArrives() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("partial.ips")
        try Data("truncated simulator report".utf8).write(to: file)
        let source = CrashReportSource(directory: directory, paths: fixture.paths)
        _ = try source.inspect(store: fixture.store)
        XCTAssertFalse(source.evidenceComplete)
        try runtimeReport().write(to: file)
        _ = try source.inspect(store: fixture.store)
        XCTAssertTrue(source.evidenceComplete)
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testDelayedCriticalEventCannotRegressFailureGeneration() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        _ = try fixture.store.ingest([criticalEvent("new", at: 1000, launch: 950)], now: Date(timeIntervalSince1970: 1100))
        _ = try fixture.store.ingest([criticalEvent("late", at: 500, launch: 450)], now: Date(timeIntervalSince1970: 1100))
        XCTAssertEqual(try fixture.store.reasons().first?.trigger.occurredAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(try fixture.store.read().blocks[device]?.occurredAt, Date(timeIntervalSince1970: 1000))
    }

    func testInfrastructureResolutionPreservesOwnedAppCancellationInEitherOrder() throws {
        for appFirst in [true, false] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
            let app = [event("app-one", at: 100, launch: 95), event("app-two", at: 101, launch: 95)]
            let system = [criticalEvent("system", at: 111, launch: 110)]
            for reports in appFirst ? [app, system] : [system, app] { _ = try fixture.store.ingest(reports, now: Date(timeIntervalSince1970: 120)) }
            let reason = try XCTUnwrap(fixture.store.reasons().first { $0.kind == .criticalInfrastructure })
            XCTAssertTrue(try fixture.store.resolveInfrastructure(reason))
            XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
            XCTAssertEqual(try fixture.store.read().blocks[device]?.processName, "App")
        }
    }

    func testClassificationsSurviveRepeatedLegacyHistoryRewritesWithoutNewEvents() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let report = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "procName": "intelligencetasksd", "procPath": "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd",
            "bundleInfo": ["CFBundleIdentifier": "com.apple.intelligencetasksd"],
        ])))
        _ = try fixture.store.ingest([report], now: report.occurredAt.addingTimeInterval(1))
        let history = fixture.paths.root.appendingPathComponent("crash-history.json")
        for _ in 0..<3 {
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [String: Any])
            legacy["incidents"] = (legacy["incidents"] as? [[String: Any]])?.map { $0.filter { $0.key != "kind" && $0.key != "isCriticalSystemService" } }
            try JSONSerialization.data(withJSONObject: legacy).write(to: history)
            XCTAssertEqual(try fixture.store.read().incidents.first?.kind, .backgroundService)
            XCTAssertTrue(try fixture.store.read().blocks.isEmpty)
        }
    }

    func testAcknowledgedCriticalClassificationSurvivesLegacyWriterWithoutReblocking() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let report = criticalEvent("system", at: 110, launch: 100)
        var classified = report
        classified.kind = .criticalInfrastructure
        _ = try fixture.store.ingest([classified], now: Date(timeIntervalSince1970: 120))
        try fixture.store.acknowledge(deviceID: device, at: Date(timeIntervalSince1970: 125))
        let history = fixture.paths.root.appendingPathComponent("crash-history.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [String: Any])
        legacy["incidents"] = (legacy["incidents"] as? [[String: Any]])?.map { $0.filter { $0.key != "kind" && $0.key != "isCriticalSystemService" } }
        try JSONSerialization.data(withJSONObject: legacy).write(to: history)
        XCTAssertEqual(try fixture.store.read().incidents.first?.kind, .criticalInfrastructure)
        XCTAssertEqual(try fixture.store.read().acknowledgments[device], Date(timeIntervalSince1970: 125))
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
    }

    func testConsumedReportMigrationClassifiesRetainedEvidenceWithoutReplayingEvictedIncidents() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try runtimeReport()
        let parsed = try XCTUnwrap(SimulatorCrashReport.parse(data))
        var retained = parsed
        retained.kind = nil
        retained.isCriticalSystemService = nil
        var state = CrashLoopState()
        state.incidents = [retained]
        state.acknowledgments[device] = parsed.occurredAt.addingTimeInterval(1)
        let history = fixture.paths.root.appendingPathComponent("crash-history.json")
        try RecoveryFile.write(state, at: history)
        var fingerprints = [String: String]()
        for (name, contents) in [("retained.ips", data), ("evicted.ips", try runtimeReport(changes: ["incident": "evicted"]))] {
            let file = directory.appendingPathComponent(name)
            try contents.write(to: file)
            let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            fingerprints[name] = "\(attributes.fileSize!):\(attributes.contentModificationDate!.timeIntervalSince1970)"
        }
        let progress: [String: Any] = ["directory": directory.standardizedFileURL.path, "fingerprints": fingerprints]
        try JSONSerialization.data(withJSONObject: progress).write(to: fixture.paths.root.appendingPathComponent("crash-report-progress-v2.json"))
        let before = try Data(contentsOf: history)
        let source = CrashReportSource(directory: directory, paths: fixture.paths)
        XCTAssertTrue(try source.inspect(store: fixture.store).isEmpty)
        XCTAssertEqual(try Data(contentsOf: history), before)
        XCTAssertEqual(try fixture.store.read().incidents.map(\.incidentID), [parsed.incidentID])
        XCTAssertEqual(try fixture.store.read().incidents.first?.kind, .criticalInfrastructure)
        XCTAssertEqual(try fixture.store.read().acknowledgments, state.acknowledgments)
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertTrue(try fixture.store.reasons().isEmpty)
        let metadata = fixture.paths.root.appendingPathComponent("crash-classifications.json")
        let modified = try FileManager.default.attributesOfItem(atPath: metadata.path)[.modificationDate] as? Date
        _ = try source.inspect(store: fixture.store)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: metadata.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(try Data(contentsOf: history), before)
    }

    func testClassificationMigrationCannotInventProofForMissingRawEvidence() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        var state = CrashLoopState()
        state.incidents = [event("no-raw-report", at: 100, launch: 95)]
        try RecoveryFile.write(state, at: fixture.paths.root.appendingPathComponent("crash-history.json"))
        try fixture.store.classifyRetained([criticalEvent("other-incident", at: 100, launch: 95)], now: Date(timeIntervalSince1970: 120))
        XCTAssertNil(try fixture.store.read().incidents.first?.kind)
        XCTAssertTrue(try fixture.store.reasons().isEmpty)
    }

    func testClassificationProofRepairsPolicyAfterInterruptedMetadataOnlyUpdate() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let report = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "procName": "intelligencetasksd", "procPath": "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd",
            "bundleInfo": ["CFBundleIdentifier": "com.apple.intelligencetasksd"],
        ])))
        var legacy = report
        legacy.kind = nil
        let second = SimulatorCrashReport(incidentID: "second", deviceID: device, occurredAt: report.occurredAt, launchedAt: report.launchedAt, signature: report.signature, processName: report.processName)
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: report.launchedAt.addingTimeInterval(-1))
        _ = try fixture.store.ingest([legacy, second], now: report.occurredAt.addingTimeInterval(1))
        try RecoveryFile.write([report.incidentID: report], at: fixture.paths.root.appendingPathComponent("crash-classifications.json"))
        try fixture.store.beginScope(id: "next", deviceIDs: [], startedAt: report.occurredAt.addingTimeInterval(1))
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        _ = try fixture.store.ingest([report], now: report.occurredAt.addingTimeInterval(2))
        XCTAssertEqual(try CrashReasonStore(paths: fixture.paths).read().reasons.values.first?.kind, .backgroundService)
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
    }

    func testFailedHistoryEvictionPreservesClassificationProofUntilRetryCommits() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let reports = (0..<512).map { index in
            SimulatorCrashReport(incidentID: "old-\(index)", deviceID: device, occurredAt: Date(timeIntervalSince1970: Double(index + 100)), launchedAt: Date(timeIntervalSince1970: 90), signature: "background", processName: "Background", kind: .backgroundService)
        }
        _ = try fixture.store.ingest(reports, now: Date(timeIntervalSince1970: 1000))
        let history = fixture.paths.root.appendingPathComponent("crash-history.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [String: Any])
        legacy["incidents"] = (legacy["incidents"] as? [[String: Any]])?.map { $0.filter { $0.key != "kind" } }
        try JSONSerialization.data(withJSONObject: legacy).write(to: history)
        let next = SimulatorCrashReport(incidentID: "new", deviceID: device, occurredAt: Date(timeIntervalSince1970: 700), launchedAt: Date(timeIntervalSince1970: 690), signature: "background", processName: "Background", kind: .backgroundService)
        let failing = CrashLoopStore(paths: fixture.paths, commitHistory: { _ in throw DeviceManagementError.failed("history commit failed") })
        XCTAssertThrowsError(try failing.ingest([next], now: Date(timeIntervalSince1970: 1000)))
        XCTAssertEqual(try fixture.store.read().incidents.count, 512)
        XCTAssertEqual(try fixture.store.read().incidents.first?.incidentID, "old-0")
        XCTAssertTrue(try fixture.store.read().incidents.allSatisfy { $0.kind == .backgroundService })
        _ = try fixture.store.ingest([next], now: Date(timeIntervalSince1970: 1000))
        let proof = try XCTUnwrap(RecoveryFile.read([String: SimulatorCrashReport].self, at: fixture.paths.root.appendingPathComponent("crash-classifications.json")))
        XCTAssertEqual(proof.count, 512)
        XCTAssertNil(proof["old-0"])
        XCTAssertNotNil(proof["new"])
    }

    func testLegacyBackgroundClassificationEnrichmentRemovesBlockAndCancellationWithoutDuplicates() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let report = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "procName": "intelligencetasksd", "procPath": "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd",
            "bundleInfo": ["CFBundleIdentifier": "com.apple.intelligencetasksd"],
        ])))
        var old = report
        old.kind = nil
        var second = old
        second = SimulatorCrashReport(incidentID: "second", deviceID: report.deviceID, occurredAt: report.occurredAt, launchedAt: report.launchedAt, signature: report.signature, processName: report.processName)
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: report.launchedAt.addingTimeInterval(-1))
        _ = try fixture.store.ingest([old, second], now: report.occurredAt.addingTimeInterval(1))
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
        XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
        _ = try fixture.store.ingest([report], now: report.occurredAt.addingTimeInterval(1))
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
        XCTAssertEqual(try fixture.store.read().incidents.count, 2)
    }

    func testCriticalInfrastructureCannotOverwriteApplicationFailure() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        _ = try fixture.store.ingest([event("app-one", at: 100, launch: 95), event("app-two", at: 101, launch: 95)], now: Date(timeIntervalSince1970: 110))
        _ = try fixture.store.ingest([criticalEvent("system", at: 111, launch: 110)], now: Date(timeIntervalSince1970: 120))
        XCTAssertEqual(try fixture.store.read().blocks[device]?.processName, "App")
    }

    func testVerifiedInfrastructureResolutionPreservesApplicationFailureAndAcknowledgments() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        _ = try fixture.store.ingest([criticalEvent("system", at: 100, launch: 95)], now: Date(timeIntervalSince1970: 110))
        let expected = try XCTUnwrap(fixture.store.reasons().first)
        _ = try fixture.store.ingest([event("app-one", at: 111, launch: 110), event("app-two", at: 112, launch: 110)], now: Date(timeIntervalSince1970: 120))
        XCTAssertTrue(try fixture.store.resolveInfrastructure(expected))
        XCTAssertEqual(try fixture.store.reasons().map(\.kind), [.application])
        XCTAssertEqual(try fixture.store.read().blocks[device]?.processName, "App")
        XCTAssertTrue(try fixture.store.read().acknowledgments.isEmpty)
    }

    func testInfrastructureResolutionCannotEraseNewerFailureOrSuppressDelayedEvents() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        _ = try fixture.store.ingest([criticalEvent("one", at: 100, launch: 95)], now: Date(timeIntervalSince1970: 110))
        let original = try XCTUnwrap(fixture.store.reasons().first)
        _ = try fixture.store.ingest([criticalEvent("two", at: 111, launch: 110)], now: Date(timeIntervalSince1970: 120))
        XCTAssertFalse(try fixture.store.resolveInfrastructure(original))
        let current = try XCTUnwrap(fixture.store.reasons().first)
        XCTAssertTrue(try fixture.store.resolveInfrastructure(current))
        _ = try fixture.store.ingest([criticalEvent("late", at: 115, launch: 110)], now: Date(timeIntervalSince1970: 130))
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testCriticalCrashWithoutOwnedScopeQuarantinesDeviceWithoutCancellation() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let report = criticalEvent("system", at: 110, launch: 100)
        XCTAssertTrue(try fixture.store.ingest([report], now: Date(timeIntervalSince1970: 120)).isEmpty)
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
        XCTAssertNoThrow(try fixture.store.requireHealthy([other]))
        XCTAssertEqual(try fixture.store.read().incidents, [report])
        XCTAssertTrue(try fixture.store.ingest([report], now: Date(timeIntervalSince1970: 125)).isEmpty)
        XCTAssertEqual(try fixture.store.read().incidents.count, 1)
    }

    func testFirstCriticalOwnedCrashBlocksButOrdinaryCrashStillNeedsTwo() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device, other], startedAt: Date(timeIntervalSince1970: 90))
        let critical = criticalEvent("system", at: 110, launch: 100)
        XCTAssertEqual(try fixture.store.ingest([critical], now: Date(timeIntervalSince1970: 120)).map(\.scopeID), ["scope"])
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
        XCTAssertTrue(try fixture.store.ingest([event("app", at: 110, launch: 100, deviceID: other)], now: Date(timeIntervalSince1970: 120)).isEmpty)
        XCTAssertNoThrow(try fixture.store.requireHealthy([other]))
    }

    func testPreexistingCriticalServiceBlocksWithoutAttributingCurrentScope() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(try fixture.store.ingest([criticalEvent("old-process", at: 110, launch: 90)], now: Date(timeIntervalSince1970: 120)).isEmpty)
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
        XCTAssertNotEqual(try fixture.store.read().blocks[device]?.scopeID, "scope")
    }

    func testCriticalFutureAndAcknowledgedReportsCannotReblock() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        XCTAssertTrue(try fixture.store.ingest([criticalEvent("future", at: 130, launch: 100)], now: Date(timeIntervalSince1970: 120)).isEmpty)
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        _ = try fixture.store.ingest([criticalEvent("one", at: 110, launch: 100)], now: Date(timeIntervalSince1970: 120))
        try fixture.store.acknowledge(deviceID: device, at: Date(timeIntervalSince1970: 125))
        _ = try fixture.store.ingest([criticalEvent("late", at: 115, launch: 100)], now: Date(timeIntervalSince1970: 140))
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        _ = try fixture.store.ingest([criticalEvent("new", at: 130, launch: 126)], now: Date(timeIntervalSince1970: 140))
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testAcknowledgingOneDeviceDoesNotSuppressOtherScopeCancellation() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device, other], startedAt: Date(timeIntervalSince1970: 90))
        let second = SimulatorCrashReport(incidentID: "second", deviceID: other, occurredAt: Date(timeIntervalSince1970: 111), launchedAt: Date(timeIntervalSince1970: 100), signature: "runtime", processName: "PosterBoard", isCriticalSystemService: true)
        _ = try fixture.store.ingest([criticalEvent("first", at: 110, launch: 100), second], now: Date(timeIntervalSince1970: 120))
        try fixture.store.acknowledge(deviceID: other, at: Date(timeIntervalSince1970: 125))
        XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
        try fixture.store.acknowledge(deviceID: device, at: Date(timeIntervalSince1970: 125))
        XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
    }

    func testFailedIngestionDoesNotCommitScanProgress() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runtimeReport().write(to: directory.appendingPathComponent("critical.ips"))
        let history = fixture.paths.root.appendingPathComponent("crash-history.json")
        try Data("invalid".utf8).write(to: history)
        let source = CrashReportSource(directory: directory, paths: fixture.paths)
        let now = Date(timeIntervalSince1970: 1_792_920_700)
        XCTAssertThrowsError(try source.inspect(store: fixture.store, now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("crash-report-progress-v2.json").path))
        try FileManager.default.removeItem(at: history)
        _ = try source.inspect(store: fixture.store, now: now)
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testFutureReportRemainsPendingUntilItsEventTime() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runtimeReport().write(to: directory.appendingPathComponent("critical.ips"))
        _ = try CrashReportSource(directory: directory, paths: fixture.paths).inspect(store: fixture.store, now: Date(timeIntervalSince1970: 1_792_920_690))
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        _ = try CrashReportSource(directory: directory, paths: fixture.paths).inspect(store: fixture.store, now: Date(timeIntervalSince1970: 1_792_920_700))
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testDueUnreadableRetriesCannotHideUnscannedEvidence() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runtimeReport().write(to: directory.appendingPathComponent("critical.ips"))
        for index in 0..<64 {
            let url = directory.appendingPathComponent("unreadable-\(index).ips")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60), .posixPermissions: 0], ofItemAtPath: url.path)
        }
        _ = try CrashReportSource(directory: directory, paths: fixture.paths).inspect(store: fixture.store, now: Date(timeIntervalSince1970: 1_792_920_700))
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        _ = try CrashReportSource(directory: directory, paths: fixture.paths).inspect(store: fixture.store, now: Date(timeIntervalSince1970: 1_792_920_800))
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testLegacyHistoryWriterCannotEraseOwnedCancellation() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        _ = try fixture.store.ingest([criticalEvent("system", at: 110, launch: 100)], now: Date(timeIntervalSince1970: 120))
        let url = fixture.paths.root.appendingPathComponent("crash-history.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        legacy["scopes"] = (legacy["scopes"] as? [[String: Any]])?.map { item in item.filter { $0.key != "cancellations" } }
        legacy["incidents"] = (legacy["incidents"] as? [[String: Any]])?.map { item in item.filter { $0.key != "isCriticalSystemService" } }
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
    }

    func testRuntimePosterBoardReportUsesSimulatorCoalition() throws {
        let parsed = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport()))
        XCTAssertEqual(parsed.deviceID, device)
        XCTAssertEqual(parsed.processName, "PosterBoard")
        XCTAssertEqual(parsed.isCriticalSystemService, true)
        XCTAssertEqual(parsed.occurredAt.timeIntervalSince1970, 1_792_920_696.4964, accuracy: 0.001)
    }

    func testCriticalClassificationRequiresRuntimeProcessBundleAndExecutable() throws {
        let ordinary = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "procPath": "/Users/USER/Library/Developer/CoreSimulator/Devices/\(device)/data/PosterBoard.app/PosterBoard",
        ])))
        XCTAssertNotEqual(ordinary.isCriticalSystemService, true)
        for changes: [String: Any] in [
            ["procName": "Other"],
            ["bundleInfo": ["CFBundleIdentifier": "test.PosterBoard"]],
            ["procPath": "/Volumes/VOLUME/*/Other.app/PosterBoard"],
        ] {
            XCTAssertNotEqual(try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: changes))).isCriticalSystemService, true)
        }
        let spring = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "procName": "SpringBoard", "bundleInfo": ["CFBundleIdentifier": "com.apple.springboard"],
            "procPath": "/Volumes/VOLUME/*/SpringBoard.app/SpringBoard",
        ])))
        XCTAssertEqual(spring.isCriticalSystemService, true)
    }

    func testCriticalClassificationSurvivesHistoryRoundTripAndLegacyReportsDecode() throws {
        let critical = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport()))
        XCTAssertEqual(try JSONDecoder().decode(SimulatorCrashReport.self, from: JSONEncoder().encode(critical)), critical)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(critical)) as? [String: Any])
        legacy.removeValue(forKey: "isCriticalSystemService")
        let decoded = try JSONDecoder().decode(SimulatorCrashReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.isCriticalSystemService)
    }

    func testRuntimeReportRejectsMissingMalformedAndConflictingSimulatorEvidence() throws {
        for coalition in ["", "com.apple.CoreSimulator.SimDevice.invalid", "com.apple.CoreSimulator.SimDevice.\(device).extra"] {
            XCTAssertNil(SimulatorCrashReport.parse(try runtimeReport(changes: ["coalitionName": coalition])))
        }
        XCTAssertNil(SimulatorCrashReport.parse(try runtimeReport(changes: ["coalitionName": NSNull()])))
        XCTAssertNil(SimulatorCrashReport.parse(try runtimeReport(changes: ["parentProc": "launchd"])))
        XCTAssertNil(SimulatorCrashReport.parse(try runtimeReport(changes: ["parentProc": NSNull()])))
        for path in [
            "/Users/USER/Library/Developer/CoreSimulator/Devices/invalid/data/PosterBoard.app/PosterBoard",
            "/Users/USER/Library/Developer/CoreSimulator/Devices/\(other)/data/PosterBoard.app/PosterBoard",
            "/Users/USER/Library/Developer/CoreSimulator/Devices/\(device)/elsewhere/PosterBoard.app/PosterBoard",
        ] {
            XCTAssertNil(SimulatorCrashReport.parse(try runtimeReport(changes: ["procPath": path])))
        }
    }

    func testRepeatedUnchangedReportScansKeepResidentMemoryBounded() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = CrashReportSource(directory: directory)
        try autoreleasepool {
            for index in 0..<640 {
                try Data("{}".utf8).write(to: directory.appendingPathComponent("report-\(index).ips"))
            }
            for _ in 0..<20 { _ = try source.scan() }
        }
        let baseline = try residentBytes()
        var reports = 0
        for _ in 0..<160 { reports += try source.scan().count }
        let final = try residentBytes()
        XCTAssertEqual(reports, 0)
        XCTAssertLessThan(final > baseline ? final - baseline : 0, 32 * 1_024 * 1_024)
    }

    func testSourceDeliversAndDeduplicatesReportsAcrossPoolBoundaries() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let path = fixture.paths.root.appendingPathComponent("report.ips")
        try report(incident: "one").write(to: path)
        let source = CrashReportSource(directory: fixture.paths.root)
        let first = try XCTUnwrap(source.scan().first)
        XCTAssertTrue(try source.scan().isEmpty)
        try report(incident: "second-incident").write(to: path)
        let changed = try XCTUnwrap(source.scan().first)
        XCTAssertEqual(first.incidentID, "one")
        XCTAssertEqual(first.deviceID, device)
        XCTAssertEqual(changed.incidentID, "second-incident")
        XCTAssertEqual(first.signature, changed.signature)
        XCTAssertTrue(try source.scan().isEmpty)
    }

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

    private func residentBytes() throws -> UInt64 {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(size)) == size else {
            throw NSError(domain: "memory inspection", code: Int(errno))
        }
        return info.pti_resident_size
    }

    private func event(_ id: String, at: TimeInterval, launch: TimeInterval, deviceID: String? = nil) -> SimulatorCrashReport {
        SimulatorCrashReport(incidentID: id, deviceID: deviceID ?? device, occurredAt: Date(timeIntervalSince1970: at), launchedAt: Date(timeIntervalSince1970: launch), signature: "same-build-and-stack", processName: "App")
    }

    private func criticalEvent(_ id: String, at: TimeInterval, launch: TimeInterval) -> SimulatorCrashReport {
        SimulatorCrashReport(incidentID: id, deviceID: device, occurredAt: Date(timeIntervalSince1970: at), launchedAt: Date(timeIntervalSince1970: launch), signature: "critical-runtime", processName: "PosterBoard", isCriticalSystemService: true)
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

    private func runtimeReport(changes: [String: Any] = [:]) throws -> Data {
        var threads = Array(repeating: [String: Any](), count: 7)
        threads[6] = ["frames": [["symbol": "-[PRPosterDescriptor _initWithPath:].cold.1", "imageIndex": 55]]]
        var images = Array(repeating: [String: String](), count: 56)
        images[0] = ["name": "PosterBoard", "uuid": "3fba9cd1-df77-3558-8bac-6aad49a14356"]
        images[55] = ["name": "PosterKit", "uuid": "c111572c-6af7-3c18-8606-60e379a5a8c1"]
        var body: [String: Any] = [
            "incident": "85EA7810-B83A-4654-8439-5E2C7C1610B4", "procName": "PosterBoard",
            "captureTime": "2026-10-25 16:31:36.4964 +0700", "procLaunch": "2026-10-25 16:31:29.6029 +0700",
            "procPath": "/Volumes/VOLUME/*/PosterBoard.app/PosterBoard", "parentProc": "launchd_sim",
            "coalitionName": "com.apple.CoreSimulator.SimDevice.\(device)",
            "bundleInfo": ["CFBundleIdentifier": "com.apple.PosterBoard"],
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"], "faultingThread": 6,
            "threads": threads, "usedImages": images,
        ]
        body.merge(changes) { _, replacement in replacement }
        return Data("{\"app_name\":\"PosterBoard\",\"platform\":7,\"bug_type\":\"309\"}\n".utf8)
            + (try JSONSerialization.data(withJSONObject: body))
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
