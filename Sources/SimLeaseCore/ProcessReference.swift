import Darwin
import Foundation

public struct ProcessReference: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startMicroseconds: UInt64

    public init(pid: Int32, startMicroseconds: UInt64) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
    }

    public static func current() throws -> ProcessReference {
        guard let value = capture(pid: getpid()) else {
            throw SimulatorTaskError.unverifiedProcess(getpid())
        }
        return value
    }

    public static func capture(pid: Int32) -> ProcessReference? {
        guard let info = info(pid: pid) else { return nil }
        return ProcessReference(
            pid: pid,
            startMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        )
    }

    public var state: ProcessIdentityState {
        guard pid > 0, startMicroseconds > 0 else { return .unknown }
        if let current = Self.capture(pid: pid) {
            return current == self ? .matching : .reused
        }
        return kill(pid, 0) != 0 && errno == ESRCH ? .missing : .unknown
    }

    public func isAncestor(of pid: Int32) -> Bool {
        guard state == .matching else { return false }
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted {
            if current == self.pid { return true }
            guard let info = Self.info(pid: current) else { return false }
            current = Int32(info.pbi_ppid)
        }
        return false
    }

    public static func isRunning(pid: Int32) -> Bool {
        if let info = info(pid: pid) { return info.pbi_status != 5 }
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = query.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
        }
        if result == 0 {
            return size > 0 && info.kp_proc.p_stat != 5
        }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    static func info(pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let count = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
        }
        return count == size ? info : nil
    }
}
