import Foundation
import XCTest
@testable import SimLeaseCore

final class ProcessSimulatorDeviceManagerTests: XCTestCase {
    func testServiceProbeRequiresPositivePIDAndExactServiceLabel() {
        let pids = ProcessSimulatorDeviceManager.parseServicePIDs("PID Status Label\n12 0 com.apple.SpringBoard\n- 0 com.apple.PosterBoard\n-7 0 bad\n15 bad invalid\n99 0 com.apple.SpringBoard.extra")
        XCTAssertEqual(pids["com.apple.SpringBoard"], 12)
        XCTAssertNil(pids["com.apple.PosterBoard"])
        XCTAssertNil(pids["bad"])
        XCTAssertNil(pids["invalid"])
    }

    func testMalformedPairInventoryCannotProveDeviceUnpaired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("xcrun")
        try Data("#!/bin/sh\nprintf '%s' '{\"pairs\":{\"pair\":{\"phone\":\"unreadable\"}}}'\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertThrowsError(try ProcessSimulatorDeviceManager(environment: [:], xcrunURL: tool).pairedDeviceIDs())
    }
    func testCrashedMutationIsUnsettledWhileNormalNonzeroExitIsDefinitive() throws {
        for crash in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let tool = root.appendingPathComponent("xcrun")
            let script = crash ? "#!/bin/sh\nkill -TERM $$\n" : "#!/bin/sh\nexit 7\n"
            try Data(script.utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let manager = ProcessSimulatorDeviceManager(environment: [:], xcrunURL: tool)
            XCTAssertThrowsError(try manager.bootAndWait("11111111-1111-4111-8111-111111111111")) {
                if crash {
                    guard case DeviceManagementError.unsettled = $0 else { return XCTFail("crashed mutation was treated as settled") }
                } else {
                    guard case DeviceManagementError.failed = $0 else { return XCTFail("normal failure was treated as uncertain") }
                }
            }
        }
    }
}
