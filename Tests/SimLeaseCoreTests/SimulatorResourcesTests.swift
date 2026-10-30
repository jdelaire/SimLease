import XCTest
@testable import SimLeaseCore

final class SimulatorResourcesTests: XCTestCase {
    private let device = "5855AB2E-0078-4A4B-9149-780B23A0AA1C"

    func testDeviceIDFromBootstrapArgument() {
        let path = "/Users/a/Library/Developer/XCTestDevices/\(device)/data/var/run/launchd_bootstrap.plist"
        XCTAssertEqual(SimulatorResources.deviceID(launchdArguments: ["launchd_sim", path]), device)
        XCTAssertEqual(SimulatorResources.deviceID(launchdArguments: ["launchd_sim", path.lowercased()]), device)
        XCTAssertNil(SimulatorResources.deviceID(launchdArguments: ["launchd_sim", "/Users/a/\(device)/data/var/run/other.plist"]))
        XCTAssertNil(SimulatorResources.deviceID(launchdArguments: ["launchd_sim", "/Users/a/not-a-uuid/data/var/run/launchd_bootstrap.plist"]))
    }

    func testMeasureSumsDescendantsOnly() {
        let snapshot = SimulatorResourceSnapshot(takenAtNanoseconds: 0, roots: [device: 10], processes: processes([
            (10, 1, 100, 0), (11, 10, 200, 0), (12, 10, 300, 0), (13, 11, 400, 0), (20, 1, 999, 0),
        ]))
        XCTAssertEqual(SimulatorResources.measure(snapshot, nil)[device], SimulatorResourceUsage(memoryBytes: 1000, processCount: 4, cpuPercent: nil))
        XCTAssertEqual(SimulatorResources.processes(deviceID: device, in: snapshot).map(\.pid), [13, 12, 11, 10])
    }

    func testCPUPercentUsesDeltasOfSurvivingProcesses() {
        let first = SimulatorResourceSnapshot(takenAtNanoseconds: 1_000_000_000, roots: [device: 10], processes: processes([
            (10, 1, 1, 0), (11, 10, 1, 0), (12, 10, 1, 0), (13, 10, 1, 0),
        ]))
        var later = processes([(10, 1, 1, 250_000_000), (11, 10, 1, 500_000_000), (13, 10, 1, 900_000_000)])
        later[13] = SimulatorProcessSample(pid: 13, parentPID: 10, name: "p13", startMicroseconds: 99, footprintBytes: 1, cpuNanoseconds: 900_000_000)
        let second = SimulatorResourceSnapshot(takenAtNanoseconds: 1_500_000_000, roots: [device: 10], processes: later)
        let usage = SimulatorResources.measure(first, second)[device]
        XCTAssertEqual(usage?.cpuPercent ?? -1, 150, accuracy: 0.001)
        XCTAssertEqual(usage?.processCount, 3)
    }

    func testUnreadableRootYieldsNoMeasurement() {
        let snapshot = SimulatorResourceSnapshot(takenAtNanoseconds: 0, roots: [device: 10], processes: processes([(11, 10, 200, 0)]))
        XCTAssertNil(SimulatorResources.measure(snapshot, nil)[device])
    }

    func testCacheRoundTrip() throws {
        let paths = LeasePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let cache = SimulatorResourceCache(paths: paths)
        XCTAssertNil(cache.read())
        let snapshot = SimulatorResourceSnapshot(takenAtNanoseconds: 42, roots: [device: 10], processes: processes([(10, 1, 5, 7)]))
        cache.write(snapshot)
        XCTAssertEqual(cache.read(), snapshot)
    }

    private func processes(_ rows: [(Int32, Int32, UInt64, UInt64)]) -> [Int32: SimulatorProcessSample] {
        Dictionary(uniqueKeysWithValues: rows.map { pid, parent, bytes, cpu in
            (pid, SimulatorProcessSample(pid: pid, parentPID: parent, name: "p\(pid)", startMicroseconds: 1, footprintBytes: bytes, cpuNanoseconds: cpu))
        })
    }
}
