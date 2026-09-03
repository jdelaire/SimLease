import Foundation
import XCTest
@testable import SimLeaseCore

final class ExecutableResolverTests: XCTestCase {
    func testSkipsShimDirectoryAndReturnsNextExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shimDirectory = root.appendingPathComponent("shims", isDirectory: true)
        let toolsDirectory = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeExecutable(at: shimDirectory.appendingPathComponent("xcrun"))
        let expected = toolsDirectory.appendingPathComponent("xcrun")
        try makeExecutable(at: expected)

        let resolved = try ExecutableResolver.resolve(
            name: "xcrun",
            path: "\(shimDirectory.path):\(toolsDirectory.path)",
            excluding: shimDirectory
        )

        XCTAssertEqual(resolved.standardizedFileURL, expected.standardizedFileURL)
    }

    func testExclusionMatchesThroughSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let linkDirectory = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: realDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeExecutable(at: realDirectory.appendingPathComponent("xcrun"))

        XCTAssertThrowsError(
            try ExecutableResolver.resolve(
                name: "xcrun",
                path: linkDirectory.path,
                excluding: realDirectory
            )
        ) { error in
            XCTAssertEqual(error as? ExecutableResolutionError, .notFound("xcrun"))
        }
    }

    func testMissingExecutableThrowsTypedError() {
        XCTAssertThrowsError(
            try ExecutableResolver.resolve(
                name: "axe",
                path: "/tmp/no-simlease-tool-here",
                excluding: URL(fileURLWithPath: "/tmp/shims")
            )
        ) { error in
            XCTAssertEqual(error as? ExecutableResolutionError, .notFound("axe"))
        }
    }

    private func makeExecutable(at url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
