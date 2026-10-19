import Foundation

public struct WarmDeviceStore: Sendable {
    public static let idleLimit: TimeInterval = 600
    public static let capacity = 2

    private struct Registry: Codable {
        var devices = [String: Date]()
    }

    private let url: URL
    private let paths: LeasePaths

    public init(paths: LeasePaths) {
        self.paths = paths
        url = paths.root.appendingPathComponent("warm-devices.json")
    }

    public func read() throws -> [String: Date] {
        do { return try RecoveryFile.read(Registry.self, at: url)?.devices ?? [:] }
        catch { throw MetadataStoreError.corruptFile(url) }
    }

    public func add(_ ids: [String], since: Date) throws {
        try SharedStateLock.withLock(paths) {
            var devices = try read()
            for id in ids { devices[id.uppercased()] = since }
            try save(devices)
        }
    }

    public func remove(_ ids: some Sequence<String>) throws {
        let ids = Array(ids)
        try SharedStateLock.withLock(paths) {
            var devices = try read()
            let before = devices.count
            for id in ids { devices.removeValue(forKey: id.uppercased()) }
            if devices.count != before { try save(devices) }
        }
    }

    private func save(_ devices: [String: Date]) throws {
        if devices.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try RecoveryFile.write(Registry(devices: devices), at: url)
        }
    }
}

public protocol WarmDevicePolicy: Sendable {
    func reap(excluding: Set<String>) throws
    func canWarm(_ id: String) throws -> Bool
    func terminateApps(_ id: String) throws
}

public struct ProcessWarmDevicePolicy: WarmDevicePolicy {
    private let paths: LeasePaths
    private let manager: ProcessSimulatorDeviceManager
    private let shutdownService: SimulatorShutdownService

    public init(paths: LeasePaths, manager: ProcessSimulatorDeviceManager, shutdownService: SimulatorShutdownService) {
        self.paths = paths
        self.manager = manager
        self.shutdownService = shutdownService
    }

    public func reap(excluding: Set<String>) throws {
        let results = try shutdownService.reapWarmHoldingLane(excluding: excluding, now: Date())
        if let unresolved = results.first(where: { $0.outcome == .unresolved }) {
            throw SimulatorTaskError.unfinishedTask("shutdown of warm simulator \(unresolved.deviceID) is unresolved: \(unresolved.reason ?? "unknown")")
        }
    }

    public func canWarm(_ id: String) throws -> Bool {
        guard try CrashLoopStore(paths: paths).read().blocks[id] == nil else { return false }
        return try !manager.pairedDeviceIDs().contains(id)
    }

    public func terminateApps(_ id: String) throws { try manager.terminateApps(id) }
}
