import Foundation

public struct LeasePaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static var `default`: LeasePaths {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return LeasePaths(root: caches.appendingPathComponent("SimLease", isDirectory: true))
    }

    public var lock: URL {
        root.appendingPathComponent("lease.lock")
    }

    public var owner: URL {
        root.appendingPathComponent("owner.json")
    }

    public var waiters: URL {
        root.appendingPathComponent("waiters", isDirectory: true)
    }

    public var threadNames: URL {
        root.appendingPathComponent("thread-names.json")
    }

    public var cleanupPlans: URL {
        root.appendingPathComponent("cleanup-plans", isDirectory: true)
    }
}
