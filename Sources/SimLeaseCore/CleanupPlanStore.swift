import CryptoKit
import Darwin
import Foundation

private struct StoredCleanupPlan: Codable {
    let plan: CleanupPlan
    let digest: String
}

public enum CleanupPlanStoreError: Error, Equatable {
    case invalidID
    case alreadyExists
    case missing
    case expired
    case invalidIntegrity
}

public final class CleanupPlanStore: @unchecked Sendable {
    private let paths: LeasePaths
    private let fileManager: FileManager

    public init(
        paths: LeasePaths,
        fileManager: FileManager = .default
    ) throws {
        self.paths = paths
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: paths.cleanupPlans,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.cleanupPlans.path
        )
    }

    public func save(_ plan: CleanupPlan) throws {
        let destination = try planURL(id: plan.id)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CleanupPlanStoreError.alreadyExists
        }
        let payload = try JSONEncoder.simLease.encode(plan)
        let stored = StoredCleanupPlan(
            plan: plan,
            digest: Self.digest(payload)
        )
        try atomicWrite(
            JSONEncoder.simLease.encode(stored),
            to: destination
        )
    }

    public func consume(id: String, now: Date) throws -> CleanupPlan {
        let url = try planURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CleanupPlanStoreError.missing
        }
        defer { try? fileManager.removeItem(at: url) }

        guard
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder.simLease.decode(
                StoredCleanupPlan.self,
                from: data
            ),
            stored.plan.id == id,
            let payload = try? JSONEncoder.simLease.encode(stored.plan),
            Self.digest(payload) == stored.digest
        else {
            throw CleanupPlanStoreError.invalidIntegrity
        }
        guard now < stored.plan.expiresAt else {
            throw CleanupPlanStoreError.expired
        }
        return stored.plan
    }

    public func prune(now: Date) throws {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: paths.cleanupPlans,
            includingPropertiesForKeys: Array(keys)
        )
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for url in urls where isPlanFilename(url.lastPathComponent) {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff
            else {
                continue
            }
            try fileManager.removeItem(at: url)
        }
    }

    private func planURL(id: String) throws -> URL {
        guard Self.isValidID(id) else {
            throw CleanupPlanStoreError.invalidID
        }
        return paths.cleanupPlans.appendingPathComponent("\(id).json")
    }

    private func isPlanFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        return Self.isValidID(String(name.dropLast(5)))
    }

    private static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 6 && id.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination
            .deletingLastPathComponent()
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
                    failure = POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
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
