import Foundation

public struct LeasePaths: Equatable, Sendable {
    public static let maximumLanes = 3

    public let root: URL
    public let lane: Int

    public init(root: URL, lane: Int = 0) {
        self.root = root.standardizedFileURL
        self.lane = lane
    }

    public static var `default`: LeasePaths {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return LeasePaths(root: caches.appendingPathComponent("SimLease", isDirectory: true))
    }

    public func lane(_ index: Int) -> LeasePaths { LeasePaths(root: root, lane: index) }

    public var allLanes: [LeasePaths] { (0..<Self.maximumLanes).map(lane) }

    public var laneRoot: URL {
        lane == 0 ? root : root.appendingPathComponent("lane-\(lane)", isDirectory: true)
    }

    public var lock: URL {
        laneRoot.appendingPathComponent("lease.lock")
    }

    public var owner: URL {
        laneRoot.appendingPathComponent("owner.json")
    }

    public var task: URL {
        laneRoot.appendingPathComponent("task.json")
    }

    public var deviceRecovery: URL { root.appendingPathComponent("device-recovery.json") }

    public var deviceShutdown: URL { root.appendingPathComponent("device-shutdown.json") }

    public var waiters: URL {
        root.appendingPathComponent("waiters", isDirectory: true)
    }

    public var threadNames: URL {
        root.appendingPathComponent("thread-names.json")
    }

    public var cleanupPlans: URL {
        root.appendingPathComponent("cleanup-plans", isDirectory: true)
    }

    public var stateLock: URL { root.appendingPathComponent("state.lock") }

    public var reapLock: URL { root.appendingPathComponent("reap.lock") }

    public var config: URL { root.appendingPathComponent("config.json") }

    public var gate: URL { root.appendingPathComponent("gate.json") }

    public func deviceLock(_ id: String) -> URL {
        root.appendingPathComponent("device-locks", isDirectory: true).appendingPathComponent("\(id.uppercased()).lock")
    }

    public func workspaceLock(_ key: String) -> URL {
        let digest = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return root.appendingPathComponent("workspace-locks", isDirectory: true).appendingPathComponent(String(format: "%016llx.lock", digest))
    }
}
