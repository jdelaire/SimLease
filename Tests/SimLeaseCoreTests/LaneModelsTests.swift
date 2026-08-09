import Foundation
import XCTest
@testable import SimLeaseCore

final class LaneModelsTests: XCTestCase {
    func testAcquireResultRoundTripsSchemaVersionOne() throws {
        let descriptor = makeDescriptor()
        let result = LaneAcquireResult(
            schemaVersion: 1,
            state: .acquired,
            lane: descriptor,
            environment: ["SIMLEASE_LANE_FILE": "/tmp/lane.json"],
            xcodebuildArguments: [
                "-destination", "platform=iOS Simulator,id=UDID-1",
                "-derivedDataPath", "/tmp/DerivedData",
            ],
            derivedDataPath: "/tmp/DerivedData",
            resultBundlePath: "/tmp/Results/lane-1.xcresult",
            releaseCommand: ["simlease", "lane", "release"],
            nextActions: ["export SIMLEASE_LANE_FILE=/tmp/lane.json"]
        )

        let data = try JSONEncoder.simLease.encode(result)

        XCTAssertEqual(
            try JSONDecoder.simLease.decode(LaneAcquireResult.self, from: data),
            result
        )
    }

    func testLanePathsStayInsideConfiguredCacheRoot() {
        let paths = LeasePaths(root: URL(fileURLWithPath: "/tmp/cache"))

        XCTAssertEqual(paths.laneState.path, "/tmp/cache/lanes/state.json")
        XCTAssertEqual(
            paths.laneCommandLock(slot: 2).path,
            "/tmp/cache/lanes/locks/lane-2.lock"
        )
        XCTAssertEqual(
            paths.laneDerivedData.path,
            "/tmp/cache/lanes/DerivedData"
        )
        XCTAssertEqual(
            paths.laneResultBundles.path,
            "/tmp/cache/lanes/ResultBundles"
        )
    }

    private func makeDescriptor() -> LaneDescriptor {
        LaneDescriptor(
            schemaVersion: 1,
            laneID: "lane-1",
            slot: 1,
            token: "TOKEN-1",
            project: "ExplorerDex",
            threadID: "thread-1",
            threadTitle: "Simulator validation",
            udid: "UDID-1",
            deviceTypeIdentifier: "TYPE-1",
            deviceTypeName: "iPhone 17 Pro",
            runtimeIdentifier: "RUNTIME-1",
            runtimeName: "iOS 27.0",
            derivedDataPath: "/tmp/DerivedData",
            acquiredAt: Date(timeIntervalSince1970: 1_000),
            lastActivityAt: Date(timeIntervalSince1970: 1_100),
            expiresAt: Date(timeIntervalSince1970: 8_300)
        )
    }
}
