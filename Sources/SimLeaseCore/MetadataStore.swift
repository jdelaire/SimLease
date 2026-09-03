import Foundation
import Darwin

public enum MetadataStoreError: Error, Equatable {
    case corruptFile(URL)
    case invalidThreadTitle
    case invalidWaiterID
    case systemCall(String, Int32)
}

public final class MetadataStore: @unchecked Sendable {
    public let paths: LeasePaths
    private let lock = NSLock()

    public init(paths: LeasePaths) throws {
        self.paths = paths
        try Self.createDirectory(paths.root)
        try Self.createDirectory(paths.waiters)
    }

    public func writeOwner(_ owner: LeaseOwner) throws {
        try atomicWrite(JSONEncoder.simLease.encode(owner), to: paths.owner)
    }

    public func readOwner() throws -> LeaseOwner? {
        try read(LeaseOwner.self, from: paths.owner)
    }

    public func removeOwner() throws {
        try removeIfPresent(paths.owner)
    }

    public func writeWaiter(_ waiter: LeaseWaiter) throws {
        let url = try waiterURL(id: waiter.id)
        try atomicWrite(JSONEncoder.simLease.encode(waiter), to: url)
    }

    public func readWaiters() throws -> [LeaseWaiter] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: paths.waiters,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            throw error
        }

        var waiters = [LeaseWaiter]()
        for url in urls {
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            do {
                guard let waiter = try read(LeaseWaiter.self, from: url) else {
                    continue
                }
                waiters.append(waiter)
            } catch let storeError as MetadataStoreError {
                guard storeError == .corruptFile(url) else {
                    throw storeError
                }
                try quarantineCorruptWaiter(at: url, original: storeError)
            }
        }
        return waiters.sorted {
            if $0.waitingSince == $1.waitingSince {
                return $0.id < $1.id
            }
            return $0.waitingSince < $1.waitingSince
        }
    }

    private func quarantineCorruptWaiter(at url: URL, original: Error) throws {
        let quarantine = paths.waiters.appendingPathComponent(
            ".quarantine",
            isDirectory: true
        )
        do {
            try Self.createDirectory(quarantine)
            let stamp = Int(Date().timeIntervalSince1970)
            let destination = quarantine.appendingPathComponent(
                "\(url.lastPathComponent).corrupt-\(stamp).json"
            )
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw original
        }
    }

    public func removeWaiter(id: String) throws {
        try removeIfPresent(waiterURL(id: id))
    }

    public func registerThreadName(id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MetadataStoreError.invalidThreadTitle
        }

        lock.lock()
        defer { lock.unlock() }
        var names = try readThreadNames()
        names[id] = trimmed
        try atomicWrite(JSONEncoder.simLease.encode(names), to: paths.threadNames)
    }

    public func threadName(id: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try readThreadNames()[id]
    }

    private func readThreadNames() throws -> [String: String] {
        try read([String: String].self, from: paths.threadNames) ?? [:]
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw error
        }
        do {
            return try JSONDecoder.simLease.decode(Value.self, from: data)
        } catch is DecodingError {
            throw MetadataStoreError.corruptFile(url)
        }
    }

    private func waiterURL(id: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !id.isEmpty,
              id.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw MetadataStoreError.invalidWaiterID
        }
        return paths.waiters.appendingPathComponent("\(id).json")
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MetadataStoreError.systemCall("open", errno)
        }

        var writeError: MetadataStoreError?
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    writeError = .systemCall("write", errno)
                    return
                }
                offset += count
            }
        }

        if writeError == nil, fsync(descriptor) != 0 {
            writeError = .systemCall("fsync", errno)
        }
        if close(descriptor) != 0, writeError == nil {
            writeError = .systemCall("close", errno)
        }
        if let writeError {
            try? FileManager.default.removeItem(at: temporary)
            throw writeError
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw MetadataStoreError.systemCall("rename", code)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}
