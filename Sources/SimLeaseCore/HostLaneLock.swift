import Darwin
import Foundation

enum HostLaneLock {
    private static let gate = NSLock()
    nonisolated(unsafe) private static var held = Set<String>()

    static func acquire(paths: LeasePaths) throws -> Int32? {
        try gate.withLock {
            let key = paths.lock.resolvingSymlinksInPath().path
            guard !held.contains(key) else { return nil }
            let descriptor = try openDescriptor(paths)
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
        gate.withLock {
            cleanup()
            _ = lockf(descriptor, F_ULOCK, 0)
            _ = close(descriptor)
            held.remove(paths.lock.resolvingSymlinksInPath().path)
        }
    }

    static func probe<Value>(paths: LeasePaths, body: (Bool) throws -> Value) throws -> Value {
        try gate.withLock {
            if held.contains(paths.lock.resolvingSymlinksInPath().path) {
                return try body(false)
            }
            let descriptor = try openDescriptor(paths)
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

    private static func openDescriptor(_ paths: LeasePaths) throws -> Int32 {
        let descriptor = open(paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
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
