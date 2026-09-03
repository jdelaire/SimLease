import CryptoKit
import Darwin
import Foundation

private struct StoredLanePlan: Codable {
    let plan: LaneLifecyclePlan
    let digest: String
}

public enum LanePlanStoreError: Error, Equatable {
    case invalidID
    case alreadyExists
    case missing
    case expired
    case invalidIntegrity
}

public protocol LanePlanStoring: Sendable {
    func save(_ plan: LaneLifecyclePlan) throws
    func peek(id: String, now: Date) throws -> LaneLifecyclePlan
    func consume(id: String, now: Date) throws -> LaneLifecyclePlan
    func prune(now: Date) throws
}

public final class LanePlanStore: LanePlanStoring, @unchecked Sendable {
    private let paths: LeasePaths
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(paths: LeasePaths, fileManager: FileManager = .default) throws {
        self.paths = paths
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: paths.lanePlans,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.lanePlans.path
        )
    }

    public func save(_ plan: LaneLifecyclePlan) throws {
        lock.lock()
        defer { lock.unlock() }
        let destination = try planURL(id: plan.id)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw LanePlanStoreError.alreadyExists
        }
        let payload = try JSONEncoder.simLease.encode(plan)
        try atomicWrite(
            JSONEncoder.simLease.encode(StoredLanePlan(
                plan: plan,
                digest: Self.digest(payload)
            )),
            to: destination
        )
    }

    public func peek(id: String, now: Date) throws -> LaneLifecyclePlan {
        lock.lock()
        defer { lock.unlock() }
        return try validatedPlan(id: id, now: now).plan
    }

    public func consume(id: String, now: Date) throws -> LaneLifecyclePlan {
        lock.lock()
        defer { lock.unlock() }
        let stored = try validatedPlan(id: id, now: now)
        try? fileManager.removeItem(at: stored.url)
        return stored.plan
    }

    private func validatedPlan(
        id: String,
        now: Date
    ) throws -> (url: URL, plan: LaneLifecyclePlan) {
        let url = try planURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw LanePlanStoreError.missing
        }
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder.simLease.decode(
                  StoredLanePlan.self,
                  from: data
              ),
              stored.plan.id == id,
              let payload = try? JSONEncoder.simLease.encode(stored.plan),
              Self.digest(payload) == stored.digest else {
            throw LanePlanStoreError.invalidIntegrity
        }
        guard now < stored.plan.expiresAt else {
            throw LanePlanStoreError.expired
        }
        return (url, stored.plan)
    }

    public func prune(now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
        ]
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for url in try fileManager.contentsOfDirectory(
            at: paths.lanePlans,
            includingPropertiesForKeys: Array(keys)
        ) where isPlanFilename(url.lastPathComponent) {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private func planURL(id: String) throws -> URL {
        guard Self.validID(id) else { throw LanePlanStoreError.invalidID }
        return paths.lanePlans.appendingPathComponent("\(id).json")
    }

    private func isPlanFilename(_ name: String) -> Bool {
        name.hasSuffix(".json") && Self.validID(String(name.dropLast(5)))
    }

    private static func validID(_ id: String) -> Bool {
        id.utf8.count == 6 && id.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var failure: Error?
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count >= 0 else {
                    failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    return
                }
                offset += count
            }
        }
        if failure == nil, fsync(descriptor) != 0 {
            failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if close(descriptor) != 0, failure == nil {
            failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let failure {
            try? fileManager.removeItem(at: temporary)
            throw failure
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
