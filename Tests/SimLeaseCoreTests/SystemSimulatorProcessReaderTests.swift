import Darwin
import XCTest
@testable import SimLeaseCore

final class SystemSimulatorProcessReaderTests: XCTestCase {
    func testUnreapedExitedChildIsRecognizedAsZombie() throws {
        var pid: pid_t = 0
        let path = strdup("/usr/bin/true")
        defer { free(path) }
        let arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        XCTAssertEqual(posix_spawn(&pid, path, nil, nil, arguments, nil), 0)
        let deadline = Date(timeIntervalSinceNow: 5)
        while !SystemSimulatorProcessReader.isZombie(pid: pid), Date() < deadline { usleep(10_000) }
        XCTAssertTrue(SystemSimulatorProcessReader.isZombie(pid: pid))
        XCTAssertNil(ProcessReference.capture(pid: pid))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertFalse(SystemSimulatorProcessReader.isZombie(pid: getpid()))
    }

    func testProcessArgumentsIncludeExecutablePathForDeletedBinaries() throws {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        buffer += Array("/opt/homebrew/Cellar/node/26.8.2/bin/node".utf8) + [0, 0, 0]
        buffer += Array("node".utf8) + [0] + Array("/tmp/agent-device/dist/src/daemon.js".utf8) + [0]
        let parsed = try SystemSimulatorProcessReader.parseArguments(buffer)
        XCTAssertEqual(parsed.executable, "/opt/homebrew/Cellar/node/26.8.2/bin/node")
        XCTAssertEqual(parsed.arguments, ["node", "/tmp/agent-device/dist/src/daemon.js"])
    }
}
