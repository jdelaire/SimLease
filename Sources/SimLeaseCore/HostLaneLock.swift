import Darwin
import Foundation

enum HostLaneLock {
    private static let gate = NSLock()
    nonisolated(unsafe) private static var held = Set<String>()

    static func acquire(paths: LeasePaths) throws -> Int32? {
        try acquire(url: paths.lock)
    }

    static func acquire(url: URL) throws -> Int32? {
        try gate.withLock {
            let key = url.resolvingSymlinksInPath().path
            guard !held.contains(key) else { return nil }
            let descriptor = try openDescriptor(url)
            guard lockf(descriptor, F_TLOCK, 0) == 0 else {
                let code = errno
                _ = close(descriptor)
                guard code == EACCES || code == EAGAIN else {
                    throw LeaseAcquisitionError.systemCall("lockf", code)
                }
                return nil
            }
            held.insert(key)
            return descriptor
        }
    }

    static func release(paths: LeasePaths, descriptor: Int32, cleanup: () -> Void) {
        release(url: paths.lock, descriptor: descriptor, cleanup: cleanup)
    }

    static func release(url: URL, descriptor: Int32, cleanup: () -> Void = {}) {
        gate.withLock {
            cleanup()
            _ = lockf(descriptor, F_ULOCK, 0)
            _ = close(descriptor)
            held.remove(url.resolvingSymlinksInPath().path)
        }
    }

    static func probe<Value>(paths: LeasePaths, body: (Bool) throws -> Value) throws -> Value {
        try probe(url: paths.lock, body: body)
    }

    static func probe<Value>(url: URL, body: (Bool) throws -> Value) throws -> Value {
        try gate.withLock {
            if held.contains(url.resolvingSymlinksInPath().path) {
                return try body(false)
            }
            let descriptor = try openDescriptor(url)
            let isFree = lockf(descriptor, F_TLOCK, 0) == 0
            let code = errno
            defer {
                if isFree { _ = lockf(descriptor, F_ULOCK, 0) }
                _ = close(descriptor)
            }
            guard isFree || code == EACCES || code == EAGAIN else {
                throw LeaseAcquisitionError.systemCall("lockf", code)
            }
            return try body(isFree)
        }
    }

    private static func openDescriptor(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LeaseAcquisitionError.systemCall("open", errno)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw LeaseAcquisitionError.systemCall("fchmod", code)
        }
        return descriptor
    }
}

enum SharedStateLock {
    static func withLock<Value>(_ paths: LeasePaths, _ body: () throws -> Value) throws -> Value {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(paths.stateLock.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LeaseAcquisitionError.systemCall("open", errno) }
        defer { _ = close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw LeaseAcquisitionError.systemCall("flock", errno) }
        }
        return try body()
    }
}
