import Foundation
import XCTest
@testable import SimLeaseCore

final class DeviceDataInventoryTests: XCTestCase {
    private var root: URL!
    private var data: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        data = root.appendingPathComponent("Devices/11111111-1111-4111-8111-111111111111/data", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func testTargetsSkipDurableAndSymlinkedDirectories() throws {
        for path in [
            "Library/Caches/a", "Containers/Data/Application/X/Library/Caches/b", "Containers/Data/Application/X/tmp/c",
            "Library/Logs/d", "var/db/diagnostics/e", "Containers/Bundle/Application/Y/App.app/Caches/f",
            "Containers/Data/Application/X/Documents/Caches/g", "Media/tmp/h",
        ] { try write(path) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: data.appendingPathComponent("tmp"), withDestinationURL: outside)
        let targets = try DeviceDataInventory.targets(dataPath: data).map { $0.path.replacingOccurrences(of: data.path + "/", with: "") }
        XCTAssertEqual(targets.sorted(), [
            "Containers/Data/Application/X/Library/Caches", "Containers/Data/Application/X/tmp",
            "Library/Caches", "Library/Logs", "var/db/diagnostics",
        ])
    }

    func testNestedTargetsCollapseIntoTheirAncestor() throws {
        try write("Library/Logs/Tool/Caches/a")
        let targets = try DeviceDataInventory.targets(dataPath: data).map { $0.path.replacingOccurrences(of: data.path + "/", with: "") }
        XCTAssertEqual(targets, ["Library/Logs"])
        try DeviceDataInventory.clear(try DeviceDataInventory.targets(dataPath: data), within: data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("Library/Logs").path), [])
    }

    func testClearEmptiesTargetsWithoutFollowingSymlinks() throws {
        try write("Library/Caches/a")
        try write("Documents/keep")
        try fm.createSymbolicLink(at: data.appendingPathComponent("Library/Caches/link"), withDestinationURL: data.appendingPathComponent("Documents"))
        let targets = try DeviceDataInventory.targets(dataPath: data)
        try DeviceDataInventory.clear(targets, within: data)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: data.appendingPathComponent("Library/Caches").path), [])
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("Documents/keep").path))
    }

    func testClearRefusesTargetReplacedBySymlinkedComponent() throws {
        try write("var/log/a")
        let targets = try DeviceDataInventory.targets(dataPath: data)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try fm.moveItem(at: data.appendingPathComponent("var"), to: moved)
        try fm.createSymbolicLink(at: data.appendingPathComponent("var"), withDestinationURL: moved)
        XCTAssertThrowsError(try DeviceDataInventory.clear(targets, within: data))
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("log/a").path))
    }

    func testDigestChangesForSameSizeRewrite() throws {
        try write("Library/Caches/nested/a", contents: "1111")
        let targets = try DeviceDataInventory.targets(dataPath: data)
        let before = try DeviceDataInventory.measure(targets, dataPath: data)
        let file = data.appendingPathComponent("Library/Caches/nested/a")
        try fm.removeItem(at: file)
        try write("Library/Caches/nested/a", contents: "2222")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: file.path)
        let after = try DeviceDataInventory.measure(targets, dataPath: data)
        XCTAssertEqual(before.sizeBytes, after.sizeBytes)
        XCTAssertNotEqual(before.digest, after.digest)
    }

    private func write(_ path: String, contents: String = "x") throws {
        let url = data.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
