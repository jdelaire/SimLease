import Darwin
import Foundation
import XCTest
@testable import SimLeaseCore

final class CrashLoopTests: XCTestCase {
    let device = "11111111-1111-4111-8111-111111111111"
    let other = "22222222-2222-4222-8222-222222222222"

    func testDevelopmentPasteboardOrphansRequireExactIOSTuple() throws {
        let process = "dtpasteboardd"
        let path = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos/usr/libexec/\(process)"
        let image: [String: String] = ["name": process, "uuid": "33333333-3333-4333-8333-333333333333", "path": path]
        for alias in [false, true] {
            for bodyPlatform in [false, true] {
                var changes: [String: Any] = ["usedImages": [image.merging(["path": alias ? path.replacingOccurrences(of: "/Versions/A/", with: "/") : path]) { _, value in value }]]
                if bodyPlatform { changes["platform"] = 7 }
                let report = try XCTUnwrap(SimulatorCrashReport.parse(developmentReport(process: process, changes: changes)))
                XCTAssertEqual(report.processName, process)
                XCTAssertEqual(report.kind, .unknown)
                XCTAssertNotEqual(report.isCriticalSystemService, true)
            }
        }
        for changes: [String: Any] in [
            ["procName": "dtdeviceinfod"], ["codeSigningID": "com.apple.CoreDevice.dtdeviceinfod"],
            ["codeSigningID": NSNull()], ["bundleInfo": ["CFBundleIdentifier": "com.apple.CoreDevice.dtdeviceinfod"]],
            ["bundleInfo": ["CFBundleIdentifier": NSNull()]],
            ["bundleInfo": ["CFBundleIdentifier": "com.apple.CoreDevice.dtpasteboardd"], "codeSigningID": "com.apple.Other"],
            ["procPath": "/Users/USER" + path], ["procPath": path.replacingOccurrences(of: "/usr/", with: "/tmp/../usr/")],
            ["procPath": path.replacingOccurrences(of: "/Versions/A/", with: "/Versions/B/")],
            ["platform": 9], ["usedImages": []], ["usedImages": [image, image]],
            ["usedImages": [image.filter { $0.key != "uuid" }]],
            ["usedImages": [image.merging(["uuid": "invalid"]) { _, value in value }]],
            ["usedImages": [image.merging(["uuid": "44444444-4444-4444-8444-444444444444"]) { _, value in value }]],
            ["usedImages": [image.merging(["path": path.replacingOccurrences(of: "iphoneos", with: "watchos")]) { _, value in value }]],
        ] {
            XCTAssertNil(SimulatorCrashReport.parse(try developmentReport(process: process, changes: changes)))
        }
        XCTAssertNil(SimulatorCrashReport.parse(try developmentReport(process: process, platform: 9)))
        for header: [String: Any] in [["platform": 9], ["platform": NSNull()], ["slice_uuid": NSNull()], ["slice_uuid": "invalid"]] {
            XCTAssertNil(SimulatorCrashReport.parse(try developmentReport(process: process, headerChanges: header)))
        }
        let data = try developmentReport(process: process, changes: ["platform": 7])
        let newline = try XCTUnwrap(data.firstIndex(of: 10))
        let body = Data(data.suffix(from: data.index(after: newline)))
        for header: [String: Any] in [["slice_uuid": "33333333-3333-4333-8333-333333333333"], ["platform": 7]] {
            XCTAssertNil(SimulatorCrashReport.parse(try JSONSerialization.data(withJSONObject: header) + Data([10]) + body))
        }
    }

    func testDevelopmentServiceOrphansRequireExactPlatformAndImageProvenance() throws {
        for platform in [7, 9] {
            for alias in [false, true] {
                for bodyPlatform in [false, true] {
                    let name = platform == 7 ? "iphoneos" : "watchos"
                    let imagePath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/\(alias ? "Resources" : "Versions/A/Resources")/Platforms/\(name)/usr/libexec/dtdeviceinfod"
                    var changes: [String: Any] = ["usedImages": [["name": "dtdeviceinfod", "uuid": "33333333-3333-4333-8333-333333333333", "path": imagePath]]]
                    if bodyPlatform { changes["platform"] = platform }
                    let parsed = try XCTUnwrap(SimulatorCrashReport.parse(developmentReport(platform: platform, changes: changes)))
                    XCTAssertEqual(parsed.deviceID, device)
                    XCTAssertEqual(parsed.processName, "dtdeviceinfod")
                    XCTAssertEqual(parsed.kind, .unknown)
                    XCTAssertNotEqual(parsed.isCriticalSystemService, true)
                }
            }
        }
    }

    func testDevelopmentServiceOrphansRejectConflictingOrUnprovenTuples() throws {
        let path = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos/usr/libexec/dtdeviceinfod"
        let rejected: [([String: Any], [String: Any])] = [
            (["procPath": "/usr/libexec/dtdeviceinfod"], [:]),
            (["procPath": "/Users/USER" + path], [:]),
            (["procPath": path.replacingOccurrences(of: "/Versions/A/", with: "/Versions/B/")], [:]),
            (["procPath": path.replacingOccurrences(of: "/usr/", with: "/tmp/../usr/")], [:]),
            (["procName": "Other"], [:]),
            (["procName": "dtpasteboardd"], [:]),
            (["codeSigningID": "com.apple.Other"], [:]),
            (["codeSigningID": NSNull()], [:]),
            (["bundleInfo": ["CFBundleIdentifier": "test.dtdeviceinfod"]], [:]),
            (["bundleInfo": ["CFBundleIdentifier": NSNull()]], [:]),
            (["bundleInfo": ["CFBundleIdentifier": "com.apple.CoreDevice.dtdeviceinfod"], "codeSigningID": "com.apple.Other"], [:]),
            (["bundleInfo": NSNull()], [:]),
            (["parentProc": "launchd"], [:]),
            (["coalitionName": "com.apple.CoreSimulator.SimDevice.\(device).extra"], [:]),
            (["platform": 9], [:]),
            ([:], ["platform": 9]),
            ([:], ["platform": NSNull()]),
            ([:], ["platform": "7"]),
            ([:], ["platform": true]),
            ([:], ["platform": 8]),
            ([:], ["platform": 12]),
            ([:], ["slice_uuid": "44444444-4444-4444-8444-444444444444"]),
            ([:], ["slice_uuid": NSNull()]),
            (["usedImages": [["name": "dtdeviceinfod", "uuid": "33333333-3333-4333-8333-333333333333", "path": "/usr/libexec/dtdeviceinfod"]]], [:]),
            (["usedImages": [["name": "Other", "uuid": "33333333-3333-4333-8333-333333333333", "path": path]]], [:]),
            (["usedImages": [["name": "dtdeviceinfod", "uuid": "invalid", "path": path]]], [:]),
            (["captureTime": "invalid"], [:]),
            (["procLaunch": "2026-10-25 16:31:40.0000 +0700"], [:]),
            (["threads": [["frames": []]]], [:]),
        ]
        for (changes, header) in rejected {
            XCTAssertNil(SimulatorCrashReport.parse(try developmentReport(changes: changes, headerChanges: header)))
        }
        let data = try developmentReport()
        let newline = try XCTUnwrap(data.firstIndex(of: 10))
        let bodyOnly = Data(data.suffix(from: data.index(after: newline)))
        XCTAssertNil(SimulatorCrashReport.parse(bodyOnly))
        XCTAssertNil(SimulatorCrashReport.parse(Data("{\"slice_uuid\":\"33333333-3333-4333-8333-333333333333\"}\n".utf8) + bodyOnly))
        XCTAssertEqual(try XCTUnwrap(SimulatorCrashReport.parse(developmentReport(changes: ["bundleInfo": ["CFBundleIdentifier": "com.apple.CoreDevice.dtdeviceinfod"]]))).kind, .unknown)
    }

    func testDevelopmentServiceSourceConsumesUnownedAndPreexistingWithoutAttribution() throws {
        for process in ["dtdeviceinfod", "dtpasteboardd"] {
            for preexisting in [false, true] {
                let fixture = try CrashFixture()
                defer { fixture.remove() }
                let data = try developmentReport(process: process)
                let report = try XCTUnwrap(SimulatorCrashReport.parse(data))
                try fixture.store.beginScope(id: "scope", deviceIDs: preexisting ? [device] : [], startedAt: report.launchedAt.addingTimeInterval(preexisting ? 1 : -1))
                let directory = fixture.paths.root.appendingPathComponent("reports")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("development.ips")
                try data.write(to: file)
                for _ in 0..<2 {
                    let source = CrashReportSource(directory: directory, paths: fixture.paths)
                    XCTAssertTrue(try source.inspect(store: fixture.store, now: report.occurredAt.addingTimeInterval(1)).isEmpty)
                    XCTAssertTrue(source.evidenceComplete)
                }
                XCTAssertTrue(try fixture.store.read().incidents.isEmpty)
                XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
                XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
                XCTAssertEqual(try Data(contentsOf: file), data)
            }
        }
    }

    func testDevelopmentServiceSourcePreservesOwnedUnknownProtectionAcrossRestartAndRecovery() throws {
        for process in ["dtdeviceinfod", "dtpasteboardd"] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let firstData = try developmentReport(process: process)
            let first = try XCTUnwrap(SimulatorCrashReport.parse(firstData))
            let secondData = try developmentReport(process: process, changes: ["incident": "development-second", "captureTime": "2026-10-25 16:31:37.4964 +0700"])
            let second = try XCTUnwrap(SimulatorCrashReport.parse(secondData))
            let directory = fixture.paths.root.appendingPathComponent("reports")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: first.launchedAt.addingTimeInterval(-1))
            try firstData.write(to: directory.appendingPathComponent("first.ips"))
            let initial = CrashReportSource(directory: directory, paths: fixture.paths)
            XCTAssertTrue(try initial.inspect(store: fixture.store, now: second.occurredAt).isEmpty)
            XCTAssertTrue(initial.evidenceComplete)
            XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
            XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
            let critical = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport()))
            _ = try fixture.store.ingest([critical], now: second.occurredAt)
            try secondData.write(to: directory.appendingPathComponent("second.ips"))
            let restarted = CrashReportSource(directory: directory, paths: fixture.paths)
            XCTAssertEqual(try restarted.inspect(store: fixture.store, now: second.occurredAt).map(\.scopeID), ["scope"])
            XCTAssertTrue(restarted.evidenceComplete)
            XCTAssertTrue(try restarted.inspect(store: fixture.store, now: second.occurredAt).isEmpty)
            let reason = try XCTUnwrap(fixture.store.reasons().first { $0.kind == .criticalInfrastructure })
            XCTAssertTrue(try fixture.store.resolveInfrastructure(reason))
            let reopened = CrashLoopStore(paths: fixture.paths)
            XCTAssertEqual(try reopened.read().incidents.filter { $0.processName == process }.map(\.incidentID).sorted(), [first.incidentID, second.incidentID].sorted())
            XCTAssertEqual(try reopened.reasons().map(\.kind), [.unknown])
            XCTAssertThrowsError(try reopened.requireHealthy([device]))
            XCTAssertTrue(try reopened.shouldCancel(scopeID: "scope"))
        }
    }

    func testDevelopmentServiceSourceLeavesRejectedAndFutureEvidencePending() throws {
        for process in ["dtdeviceinfod", "dtpasteboardd"] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let valid = try developmentReport(process: process)
            let report = try XCTUnwrap(SimulatorCrashReport.parse(valid))
            let invalid = try developmentReport(process: process, changes: ["incident": "invalid", "codeSigningID": "com.apple.Other"])
            let future = try developmentReport(process: process, changes: ["incident": "future", "captureTime": "2026-10-25 16:32:37.4964 +0700"])
            let directory = fixture.paths.root.appendingPathComponent("reports")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, data) in [("valid", valid), ("invalid", invalid), ("future", future)] { try data.write(to: directory.appendingPathComponent(name + ".ips")) }
            try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: report.launchedAt.addingTimeInterval(-1))
            let source = CrashReportSource(directory: directory, paths: fixture.paths)
            XCTAssertTrue(try source.inspect(store: fixture.store, now: report.occurredAt).isEmpty)
            XCTAssertFalse(source.evidenceComplete)
            XCTAssertEqual(try fixture.store.read().incidents.map(\.incidentID), [report.incidentID])
            XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
            for (name, data) in [("valid", valid), ("invalid", invalid), ("future", future)] { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name + ".ips")), data) }
            let restarted = CrashReportSource(directory: directory, paths: fixture.paths)
            XCTAssertEqual(try restarted.inspect(store: fixture.store, now: report.occurredAt.addingTimeInterval(62)).map(\.scopeID), ["scope"])
            XCTAssertFalse(restarted.evidenceComplete)
            XCTAssertEqual(try fixture.store.read().incidents.count, 2)
            XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
        }
    }

    func testDevelopmentServiceIngestionFailureDoesNotConsumeReports() throws {
        for process in ["dtdeviceinfod", "dtpasteboardd"] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let data = try developmentReport(process: process)
            let report = try XCTUnwrap(SimulatorCrashReport.parse(data))
            let directory = fixture.paths.root.appendingPathComponent("reports")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("development.ips"))
            let history = fixture.paths.root.appendingPathComponent("crash-history.json")
            try Data("invalid".utf8).write(to: history)
            let source = CrashReportSource(directory: directory, paths: fixture.paths)
            XCTAssertThrowsError(try source.inspect(store: fixture.store, now: report.occurredAt))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("crash-report-progress-v2.json").path))
            try FileManager.default.removeItem(at: history)
            XCTAssertTrue(try source.inspect(store: fixture.store, now: report.occurredAt).isEmpty)
            XCTAssertTrue(source.evidenceComplete)
            XCTAssertTrue(try fixture.store.read().incidents.isEmpty)
        }
    }

    func testOwnedOrphanReportCompletesIngestionAndIsRetainedOnceAcrossRestart() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let data = try runtimeReport(changes: ["parentProc": "Exited process"])
        let report = try XCTUnwrap(SimulatorCrashReport.parse(data))
        XCTAssertEqual(report.kind, .unknown)
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("orphan.ips"))
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: report.launchedAt.addingTimeInterval(-1))
        let now = report.occurredAt.addingTimeInterval(1)
        let source = CrashReportSource(directory: directory, paths: fixture.paths)
        for _ in 0..<2 {
            XCTAssertTrue(try source.inspect(store: fixture.store, now: now).isEmpty)
            XCTAssertTrue(source.evidenceComplete)
        }
        let restarted = CrashReportSource(directory: directory, paths: fixture.paths)
        XCTAssertTrue(try restarted.inspect(store: fixture.store, now: now).isEmpty)
        XCTAssertTrue(restarted.evidenceComplete)
        XCTAssertEqual(try fixture.store.read().incidents.map(\.incidentID), [report.incidentID])
        XCTAssertEqual(try fixture.store.read().incidents.first?.kind, .unknown)
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
    }

    func testUnownedAndPreexistingOrphanReportsAreConsumedWithoutAttributingCurrentWork() throws {
        for preexisting in [false, true] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let data = try runtimeReport(changes: ["parentProc": "Exited process"])
            let report = try XCTUnwrap(SimulatorCrashReport.parse(data))
            try fixture.store.beginScope(id: "scope", deviceIDs: preexisting ? [device] : [], startedAt: report.launchedAt.addingTimeInterval(preexisting ? 1 : -1))
            let directory = fixture.paths.root.appendingPathComponent("reports")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("orphan.ips"))
            for _ in 0..<2 {
                let source = CrashReportSource(directory: directory, paths: fixture.paths)
                XCTAssertTrue(try source.inspect(store: fixture.store, now: report.occurredAt.addingTimeInterval(1)).isEmpty)
                XCTAssertTrue(source.evidenceComplete)
            }
            XCTAssertTrue(try fixture.store.read().incidents.isEmpty)
            XCTAssertTrue(try fixture.store.read().blocks.isEmpty)
            XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
        }
    }

    func testOwnedOrphanReportsStillRequireTwoMatchingIncidentsToBlockAndCancel() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let first = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: ["parentProc": "Exited process"])))
        let second = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "parentProc": "Exited process", "incident": "second", "captureTime": "2026-10-25 16:31:37.4964 +0700",
        ])))
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: first.launchedAt.addingTimeInterval(-1))
        XCTAssertTrue(try fixture.store.ingest([first], now: second.occurredAt).isEmpty)
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
        XCTAssertEqual(try fixture.store.ingest([second], now: second.occurredAt).map(\.scopeID), ["scope"])
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
        XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
        XCTAssertEqual(try fixture.store.reasons().first?.kind, .unknown)
    }

    func testSigtermTimeoutKillsAreRecordedWithoutBlocking() throws {
        let timeout: [String: Any] = [
            "procName": "nanoprefsyncd", "procPath": "/Volumes/VOLUME/*/NanoPreferencesSync.framework/nanoprefsyncd",
            "bundleInfo": ["CFBundleIdentifier": "com.apple.nanoprefsyncd"], "codeSigningID": "com.apple.nanoprefsyncd",
            "exception": ["type": "EXC_CRASH", "signal": "SIGKILL"],
            "termination": ["namespace": "LIBXPC", "indicator": "XPC_EXIT_REASON_SIGTERM_TIMEOUT", "code": 4],
        ]
        for parent in ["Exited process", "launchd_sim"] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let reports = try (0..<2).map { index in
                try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: timeout.merging([
                    "parentProc": parent, "incident": "TIMEOUT-\(index)",
                    "captureTime": "2026-10-25 16:3\(index + 1):36.4964 +0700",
                ]) { _, value in value })))
            }
            XCTAssertEqual(reports.map(\.kind), [.backgroundService, .backgroundService], parent)
            for report in reports { _ = try fixture.store.ingest([report], now: report.occurredAt) }
            XCTAssertNoThrow(try fixture.store.requireHealthy([device]), parent)
        }
        let unrelated: [[String: Any]] = [
            ["termination": ["namespace": "LIBXPC", "indicator": "XPC_EXIT_REASON_FAULT"]],
            ["termination": ["namespace": "JETSAM", "indicator": "XPC_EXIT_REASON_SIGTERM_TIMEOUT"]],
            ["exception": ["type": "EXC_CRASH", "signal": "SIGABRT"]],
            ["exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGKILL"]],
        ]
        var signatures = Set<String>()
        for change in unrelated {
            let report = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: timeout.merging(["parentProc": "Exited process"].merging(change) { _, value in value }) { _, value in value })))
            XCTAssertEqual(report.kind, .unknown)
            signatures.insert(report.signature)
        }
        let ignored = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: timeout.merging(["parentProc": "Exited process"]) { _, value in value })))
        XCTAssertFalse(signatures.contains(ignored.signature))
        let poster = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "exception": ["type": "EXC_CRASH", "signal": "SIGKILL"],
            "termination": ["namespace": "LIBXPC", "indicator": "XPC_EXIT_REASON_SIGTERM_TIMEOUT"],
        ])))
        XCTAssertEqual(poster.kind, .criticalInfrastructure)
        for (name, bundle, path) in [("PosterBoard", "com.apple.PosterBoard", "/Volumes/VOLUME/*/PosterBoard.app/PosterBoard"), ("SpringBoard", "com.apple.springboard", "/Volumes/VOLUME/*/SpringBoard.app/SpringBoard")] {
            let orphan = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
                "parentProc": "Exited process", "procName": name, "procPath": path, "bundleInfo": ["CFBundleIdentifier": bundle],
                "exception": ["type": "EXC_CRASH", "signal": "SIGKILL"],
                "termination": ["namespace": "LIBXPC", "indicator": "XPC_EXIT_REASON_SIGTERM_TIMEOUT"],
            ])))
            XCTAssertEqual(orphan.kind, .unknown, name)
        }
    }

    func testOrphanedSystemServiceNamesCannotAcquireVerifiedClassifications() throws {
        for (name, bundle, path) in [
            ("PosterBoard", "com.apple.PosterBoard", "/Volumes/VOLUME/*/PosterBoard.app/PosterBoard"),
            ("SpringBoard", "com.apple.springboard", "/Volumes/VOLUME/*/SpringBoard.app/SpringBoard"),
            ("AppIntentsLiveEntityService", "com.apple.appintents.LiveEntityService", "/Volumes/VOLUME/*/AppIntentsLiveEntitySupport.framework/XPCServices/AppIntentsLiveEntityService.xpc/AppIntentsLiveEntityService"),
            ("intelligencetasksd", "com.apple.intelligencetasksd", "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd"),
        ] {
            let report = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
                "parentProc": "Exited process", "procName": name, "procPath": path,
                "bundleInfo": ["CFBundleIdentifier": bundle],
            ])))
            XCTAssertEqual(report.kind, .unknown)
            XCTAssertNotEqual(report.isCriticalSystemService, true)
        }
    }

    func testOrphanReportAcceptsOnlyConsistentNumericSimulatorPlatforms() throws {
        for platform in [7, 8, 9, 12] {
            for (body, header): ([String: Any], [String: Any]?) in [
                ([:], ["platform": platform]),
                (["platform": platform], nil),
                (["platform": platform], ["platform": platform]),
            ] {
                let changes = body.merging(["parentProc": "Exited process"]) { _, value in value }
                XCTAssertEqual(try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: changes, header: header))).kind, .unknown)
            }
        }
        let rejected: [([String: Any], [String: Any]?)] = [
            ([:], nil), ([:], ["platform": 1]), ([:], ["platform": 4]),
            (["platform": 7], ["platform": 9]), (["platform": 9], ["platform": 7]),
            ([:], ["platform": "7"]), ([:], ["platform": NSNull()]), ([:], ["platform": true]),
            (["platform": "7"], ["platform": 7]), (["platform": NSNull()], ["platform": 7]),
            (["platform": 7], ["platform": "7"]), (["platform": 7], ["platform": NSNull()]),
            (["platform": 7.5], ["platform": 7]),
        ]
        for (body, header) in rejected {
            let changes = body.merging(["parentProc": "Exited process"]) { _, value in value }
            XCTAssertNil(SimulatorCrashReport.parse(try runtimeReport(changes: changes, header: header)))
        }
    }

    func testOrphanAttributionRequiresAppleIdentityMountedExecutableAndSimulatorCoalition() throws {
        let base: [String: Any] = ["parentProc": "Exited process"]
        for changes: [String: Any] in [
            ["bundleInfo": ["CFBundleIdentifier": "test.PosterBoard"], "codeSigningID": "com.apple.PosterBoard"],
            ["bundleInfo": ["CFBundleIdentifier": NSNull()], "codeSigningID": "com.apple.PosterBoard"],
            ["procPath": "/usr/libexec/PosterBoard"], ["procPath": "/Volumes/VOLUME/*/Other"],
            ["coalitionName": "com.apple.CoreSimulator.SimDevice.invalid"],
            ["coalitionName": "com.apple.CoreSimulator.SimDevice.\(device).extra"],
            ["coalitionName": NSNull()], ["parentProc": "launchd"], ["parentProc": NSNull()],
        ] {
            XCTAssertNil(SimulatorCrashReport.parse(try runtimeReport(changes: base.merging(changes) { _, value in value })))
        }
        XCTAssertEqual(try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: base.merging([
            "bundleInfo": [:], "codeSigningID": "com.apple.PosterBoard",
        ]) { _, value in value }))).kind, .unknown)
        XCTAssertEqual(try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: base.merging([
            "procPath": "/Users/USER/Library/Developer/CoreSimulator/Devices/\(device)/data/PosterBoard.app/PosterBoard",
        ]) { _, value in value }, header: nil))).kind, .application)
    }

    func testRejectedOrphanEvidenceRemainsPending() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let directory = fixture.paths.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try runtimeReport(changes: ["parentProc": "Exited process", "platform": 9])
        let file = directory.appendingPathComponent("conflicting.ips")
        try data.write(to: file)
        let source = CrashReportSource(directory: directory, paths: fixture.paths)
        XCTAssertTrue(try source.inspect(store: fixture.store).isEmpty)
        XCTAssertFalse(source.evidenceComplete)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertTrue(try fixture.store.read().incidents.isEmpty)
    }

    func testActiveCriticalReasonSurvivesLaterOwnedUnknownRecurrenceAcrossRestart() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let critical = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport()))
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: critical.launchedAt.addingTimeInterval(-1))
        _ = try fixture.store.ingest([critical], now: critical.occurredAt)
        let reason = try XCTUnwrap(fixture.store.reasons().first)
        let orphan = SimulatorCrashReport(incidentID: "orphan", deviceID: device, occurredAt: critical.occurredAt.addingTimeInterval(1), launchedAt: critical.launchedAt, signature: critical.signature, processName: critical.processName, kind: .unknown)
        _ = try fixture.store.ingest([orphan], now: orphan.occurredAt)
        let restarted = CrashLoopStore(paths: fixture.paths)
        XCTAssertEqual(try restarted.reasons().filter { $0.kind == .criticalInfrastructure }, [reason])
        XCTAssertEqual(try restarted.reasons().first { $0.kind == .unknown }?.trigger.occurredAt, orphan.occurredAt)
        XCTAssertEqual(try restarted.read().incidents.first { $0.incidentID == orphan.incidentID }?.kind, .unknown)
        XCTAssertEqual(try restarted.read().incidents.first { $0.incidentID == critical.incidentID }?.kind, .criticalInfrastructure)
        XCTAssertThrowsError(try restarted.requireHealthy([device]))
    }

    func testWeakerDuplicateCannotEraseCriticalProofAfterLegacyRewrite() throws {
        for classificationOnly in [false, true] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let critical = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport()))
            _ = try fixture.store.ingest([critical], now: critical.occurredAt)
            let reason = try XCTUnwrap(fixture.store.reasons().first)
            var weaker = critical
            weaker.kind = .unknown
            weaker.isCriticalSystemService = nil
            if classificationOnly { try fixture.store.classifyRetained([weaker], now: critical.occurredAt) }
            else { _ = try fixture.store.ingest([weaker], now: critical.occurredAt) }
            let history = fixture.paths.root.appendingPathComponent("crash-history.json")
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [String: Any])
            legacy["incidents"] = (legacy["incidents"] as? [[String: Any]])?.map { $0.filter { $0.key != "kind" && $0.key != "isCriticalSystemService" } }
            try JSONSerialization.data(withJSONObject: legacy).write(to: history)
            let restarted = CrashLoopStore(paths: fixture.paths)
            XCTAssertEqual(try restarted.reasons(), [reason])
            XCTAssertEqual(try restarted.read().incidents.first?.kind, .criticalInfrastructure)
            XCTAssertEqual(try restarted.read().incidents.first?.isCriticalSystemService, true)
        }
    }

    func testUnknownRepeatsAfterResolvedCriticalEvidenceStillBlockConservatively() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let critical = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport()))
        _ = try fixture.store.ingest([critical], now: critical.occurredAt)
        XCTAssertTrue(try fixture.store.resolveInfrastructure(XCTUnwrap(fixture.store.reasons().first)))
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: critical.occurredAt.addingTimeInterval(180))
        let reports = (0..<2).map { index in
            SimulatorCrashReport(incidentID: "orphan-\(index)", deviceID: device, occurredAt: critical.occurredAt.addingTimeInterval(200 + Double(index)), launchedAt: critical.occurredAt.addingTimeInterval(190), signature: critical.signature, processName: critical.processName, kind: .unknown)
        }
        XCTAssertTrue(try fixture.store.ingest([reports[0]], now: reports[0].occurredAt).isEmpty)
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertEqual(try fixture.store.ingest([reports[1]], now: reports[1].occurredAt).map(\.scopeID), ["scope"])
        XCTAssertEqual(try fixture.store.reasons().first?.kind, .unknown)
        XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
    }

    func testUnknownDuplicateCannotReblockVerifiedBackgroundServiceAfterLegacyRewrite() throws {
        for classificationOnly in [false, true] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let report = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
                "procName": "intelligencetasksd", "procPath": "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd",
                "bundleInfo": ["CFBundleIdentifier": "com.apple.intelligencetasksd"],
            ])))
            _ = try fixture.store.ingest([report], now: report.occurredAt)
            var weaker = report
            weaker.kind = .unknown
            if classificationOnly { try fixture.store.classifyRetained([weaker], now: report.occurredAt) }
            else { _ = try fixture.store.ingest([weaker], now: report.occurredAt) }
            let history = fixture.paths.root.appendingPathComponent("crash-history.json")
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [String: Any])
            legacy["incidents"] = (legacy["incidents"] as? [[String: Any]])?.map { $0.filter { $0.key != "kind" && $0.key != "isCriticalSystemService" } }
            try JSONSerialization.data(withJSONObject: legacy).write(to: history)
            let restarted = CrashLoopStore(paths: fixture.paths)
            XCTAssertEqual(try restarted.read().incidents.first?.kind, .backgroundService)
            XCTAssertNoThrow(try restarted.requireHealthy([device]))
            XCTAssertTrue(try restarted.reasons().isEmpty)
        }
    }

    func testMixedBatchKeepsCriticalAndUnknownReasonsOnTheirOwnEventTimes() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 90))
        let critical = criticalEvent("critical", at: 100, launch: 95)
        let orphan = SimulatorCrashReport(incidentID: "orphan", deviceID: device, occurredAt: Date(timeIntervalSince1970: 110), launchedAt: Date(timeIntervalSince1970: 105), signature: critical.signature, processName: critical.processName, kind: .unknown)
        _ = try fixture.store.ingest([critical, orphan], now: Date(timeIntervalSince1970: 120))
        let reasons = try fixture.store.reasons()
        let verified = try XCTUnwrap(reasons.first { $0.kind == .criticalInfrastructure })
        XCTAssertEqual(verified.trigger.occurredAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(reasons.first { $0.kind == .unknown }?.trigger.occurredAt, Date(timeIntervalSince1970: 110))
        XCTAssertTrue(try fixture.store.resolveInfrastructure(verified))
        XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
        XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
    }

    func testInfrastructureResolutionPreservesSameSignatureUnknownPairInEitherOrder() throws {
        for unknownFirst in [false, true] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: Date(timeIntervalSince1970: 80))
            let critical = criticalEvent("critical", at: 100, launch: 95)
            let start: TimeInterval = unknownFirst ? 90 : 300
            let unknown = (0..<2).map { index in
                SimulatorCrashReport(incidentID: "orphan-\(index)", deviceID: device, occurredAt: Date(timeIntervalSince1970: start + Double(index)), launchedAt: Date(timeIntervalSince1970: start - 5), signature: critical.signature, processName: critical.processName, kind: .unknown)
            }
            for batch in unknownFirst ? [unknown, [critical]] : [[critical], unknown] {
                _ = try fixture.store.ingest(batch, now: Date(timeIntervalSince1970: 400))
            }
            let reason = try XCTUnwrap(fixture.store.reasons().first { $0.kind == .criticalInfrastructure })
            XCTAssertTrue(try fixture.store.resolveInfrastructure(reason))
            let restarted = CrashLoopStore(paths: fixture.paths)
            XCTAssertThrowsError(try restarted.requireHealthy([device]))
            XCTAssertEqual(try restarted.reasons().first?.kind, .unknown)
            XCTAssertEqual(try restarted.reasons().first?.trigger.occurredAt, Date(timeIntervalSince1970: start + 1))
            XCTAssertTrue(try restarted.shouldCancel(scopeID: "scope"))
        }
    }

    func testSameBatchStrongerDuplicateUsesCanonicalVerifiedIncident() throws {
        for criticalFirst in [false, true] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let critical = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport()))
            var weaker = critical
            weaker.kind = .unknown
            weaker.isCriticalSystemService = nil
            try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: critical.launchedAt.addingTimeInterval(-1))
            let triggers = try fixture.store.ingest(criticalFirst ? [critical, weaker] : [weaker, critical], now: critical.occurredAt)
            XCTAssertEqual(triggers.map(\.scopeID), ["scope"])
            XCTAssertEqual(try fixture.store.read().incidents.count, 1)
            XCTAssertEqual(try fixture.store.reasons().first?.kind, .criticalInfrastructure)
            XCTAssertTrue(try fixture.store.shouldCancel(scopeID: "scope"))
        }
    }

    func testLegacyInfrastructureResolutionStillSuppressesOnlyItsCriticalCancellation() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let report = criticalEvent("critical", at: 100, launch: 95)
        let trigger = CrashLoopTrigger(deviceID: device, scopeID: "scope", processName: "PosterBoard", signature: "critical-runtime", occurredAt: Date(timeIntervalSince1970: 100))
        var state = CrashLoopState()
        state.incidents = [report]
        state.blocks[device] = trigger
        try RecoveryFile.write(state, at: fixture.paths.root.appendingPathComponent("crash-history.json"))
        let key = "11111111-1111-4111-8111-111111111111:critical-runtime"
        try CrashReasonStore(paths: fixture.paths).write(CrashReasonState(reasons: [key: SimulatorCrashReason(trigger: trigger, kind: .criticalInfrastructure)], resolvedThrough: [key: Date(timeIntervalSince1970: 110)]))
        try RecoveryFile.write(["scope": [device: trigger]], at: fixture.paths.root.appendingPathComponent("crash-cancellations.json"))
        XCTAssertNoThrow(try fixture.store.requireHealthy([device]))
        XCTAssertFalse(try fixture.store.shouldCancel(scopeID: "scope"))
    }

    func testVerifiedBackgroundRecurrenceCannotEraseIndependentUnknownPair() throws {
        let fixture = try CrashFixture()
        defer { fixture.remove() }
        let background = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
            "procName": "intelligencetasksd", "procPath": "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd",
            "bundleInfo": ["CFBundleIdentifier": "com.apple.intelligencetasksd"],
        ])))
        try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: background.launchedAt.addingTimeInterval(-40))
        let unknown = (0..<2).map { index in
            SimulatorCrashReport(incidentID: "orphan-\(index)", deviceID: device, occurredAt: background.occurredAt.addingTimeInterval(-20 + Double(index)), launchedAt: background.launchedAt.addingTimeInterval(-30), signature: background.signature, processName: background.processName, kind: .unknown)
        }
        _ = try fixture.store.ingest(unknown, now: background.occurredAt)
        _ = try fixture.store.ingest([background], now: background.occurredAt)
        let restarted = CrashLoopStore(paths: fixture.paths)
        XCTAssertThrowsError(try restarted.requireHealthy([device]))
        XCTAssertEqual(try restarted.reasons().first?.kind, .unknown)
        XCTAssertTrue(try restarted.shouldCancel(scopeID: "scope"))
    }

    func testMixedBatchBackgroundRecurrencePreservesNewAndActiveUnknownReasons() throws {
        for alreadyActive in [false, true] {
            let fixture = try CrashFixture()
            defer { fixture.remove() }
            let background = try XCTUnwrap(SimulatorCrashReport.parse(runtimeReport(changes: [
                "procName": "intelligencetasksd", "procPath": "/Volumes/VOLUME/*/IntelligenceTasksEngine.framework/Support/intelligencetasksd",
                "bundleInfo": ["CFBundleIdentifier": "com.apple.intelligencetasksd"],
            ])))
            try fixture.store.beginScope(id: "scope", deviceIDs: [device], startedAt: background.launchedAt.addingTimeInterval(-80))
            func unknown(_ id: String, offset: TimeInterval) -> SimulatorCrashReport {
                SimulatorCrashReport(incidentID: id, deviceID: device, occurredAt: background.occurredAt.addingTimeInterval(offset), launchedAt: background.launchedAt.addingTimeInterval(-60), signature: background.signature, processName: background.processName, kind: .unknown)
            }
            if alreadyActive {
                _ = try fixture.store.ingest([unknown("prior-0", offset: -40), unknown("prior-1", offset: -39)], now: background.occurredAt)
                XCTAssertThrowsError(try fixture.store.requireHealthy([device]))
            }
            _ = try fixture.store.ingest([unknown("current-0", offset: -20), unknown("current-1", offset: -19), background], now: background.occurredAt)
            let restarted = CrashLoopStore(paths: fixture.paths)
            XCTAssertThrowsError(try restarted.requireHealthy([device]))
            XCTAssertEqual(try restarted.reasons().first?.kind, .unknown)
            XCTAssertEqual(try restarted.reasons().first?.trigger.occurredAt, background.occurredAt.addingTimeInterval(-19))
            XCTAssertTrue(try restarted.shouldCancel(scopeID: "scope"))
            XCTAssertEqual(try restarted.read().incidents.first { $0.incidentID == background.incidentID }?.kind, .backgroundService)
        }
    }

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

    private func developmentReport(process: String = "dtdeviceinfod", platform: Int = 7, changes: [String: Any] = [:], headerChanges: [String: Any] = [:]) throws -> Data {
        let name = platform == 9 ? "watchos" : "iphoneos"
        let path = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Platforms/\(name)/usr/libexec/\(process)"
        let uuid = "33333333-3333-4333-8333-333333333333"
        let body: [String: Any] = [
            "incident": "55555555-5555-4555-8555-555555555555",
            "parentProc": "Exited process", "procName": process, "procPath": path,
            "bundleInfo": [:], "codeSigningID": "com.apple.CoreDevice.\(process)",
            "exception": ["type": "EXC_CRASH", "signal": "SIGKILL"], "faultingThread": 0,
            "threads": [["frames": [["symbol": "__sigsuspend_nocancel", "imageIndex": 0]]]],
            "usedImages": [["name": process, "uuid": uuid, "path": path]],
        ]
        let header: [String: Any] = ["platform": platform, "slice_uuid": uuid]
        return try runtimeReport(changes: body.merging(changes) { _, value in value }, header: header.merging(headerChanges) { _, value in value })
    }

    private func runtimeReport(changes: [String: Any] = [:], header: [String: Any]? = ["app_name": "PosterBoard", "platform": 7, "bug_type": "309"]) throws -> Data {
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
        let prefix = try header.map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) } ?? Data()
        return prefix + (try JSONSerialization.data(withJSONObject: body))
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
