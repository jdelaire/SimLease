import Foundation
import XCTest
@testable import SimLeaseCore

final class XcodeStorageInventoryTests: XCTestCase {
    func testInventoryAppliesCategoryThresholdsAndGuardedDefaults() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000)

        let derived = fixture.derivedData.appending(path: "OldProject")
        try fixture.directory(derived, modifiedAt: now.addingTimeInterval(-15 * 86_400))
        try fixture.plist(
            [
                "WorkspacePath": fixture.workspace.path,
                "LastAccessedDate": now.addingTimeInterval(-15 * 86_400),
            ],
            at: derived.appending(path: "info.plist")
        )
        let temporary = fixture.temporary.appending(path: "custom-derived")
        try fixture.directory(
            temporary.appending(path: "Build/Intermediates.noindex"),
            modifiedAt: now.addingTimeInterval(-2 * 86_400)
        )
        let build = fixture.workspace.appending(path: ".build")
        try fixture.directory(build, modifiedAt: now.addingTimeInterval(-15 * 86_400))
        let result = fixture.workspace.appending(path: "Evidence.xcresult")
        try fixture.directory(result, modifiedAt: now.addingTimeInterval(-31 * 86_400))
        let archive = fixture.archives.appending(path: "2026-01-01/App.xcarchive")
        try fixture.directory(archive, modifiedAt: now.addingTimeInterval(-91 * 86_400))
        let support = fixture.deviceSupport.appending(path: "iPhone16,2 27.0 (24A5390f)")
        try fixture.directory(support, modifiedAt: now)

        let inventory = try fixture.provider().inventory(now: now)
        let categories = Set(inventory.targets.map(\.category))

        XCTAssertTrue(categories.contains(.derivedData))
        XCTAssertTrue(categories.contains(.temporaryDerivedData))
        XCTAssertTrue(categories.contains(.swiftBuild))
        XCTAssertTrue(categories.contains(.resultBundle))
        XCTAssertTrue(categories.contains(.archive))
        XCTAssertTrue(categories.contains(.deviceSupport))
        XCTAssertTrue(
            inventory.targets
                .filter { $0.riskTier == .guarded }
                .allSatisfy { !$0.selectedByDefault && $0.action == .moveToTrash }
        )
        XCTAssertTrue(
            inventory.targets
                .filter { $0.riskTier == .rebuildable }
                .allSatisfy { $0.selectedByDefault && $0.action == .deletePermanently }
        )
    }

    func testActivePathIsProtectedAndNonStructuralTemporaryFolderIsIgnored() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let active = fixture.derivedData.appending(path: "Active")
        try fixture.directory(active, modifiedAt: now.addingTimeInterval(-30 * 86_400))
        let unrelated = fixture.temporary.appending(path: "old-download")
        try fixture.directory(unrelated, modifiedAt: now.addingTimeInterval(-30 * 86_400))

        let inventory = try fixture.provider(
            activePaths: [active.appending(path: "Build/Products").path]
        ).inventory(now: now)

        XCTAssertFalse(inventory.targets.contains { $0.path == active.path })
        XCTAssertEqual(
            inventory.protected.first { $0.target.path == active.path }?.reason,
            .activePath
        )
        XCTAssertFalse(inventory.targets.contains { $0.path == unrelated.path })
    }
}

private final class StorageFixture {
    let root: URL
    let home: URL
    let temporary: URL
    let workspace: URL
    let derivedData: URL
    let archives: URL
    let deviceSupport: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        home = root.appending(path: "home")
        temporary = root.appending(path: "tmp")
        workspace = home.appending(path: "Projects/App")
        let xcode = home.appending(path: "Library/Developer/Xcode")
        derivedData = xcode.appending(path: "DerivedData")
        archives = xcode.appending(path: "Archives")
        deviceSupport = xcode.appending(path: "iOS DeviceSupport")
        for url in [temporary, workspace, derivedData, archives, deviceSupport] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    func provider(activePaths: [String] = []) -> XcodeStorageInventoryProvider {
        XcodeStorageInventoryProvider(
            homeDirectory: home,
            temporaryDirectory: temporary,
            workspaceRoots: [workspace],
            activePaths: activePaths
        )
    }

    func directory(_ url: URL, modifiedAt: Date) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: url.appending(path: "payload"))
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.appending(path: "payload").path
        )
    }

    func plist(_ value: Any, at url: URL) throws {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        ).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
