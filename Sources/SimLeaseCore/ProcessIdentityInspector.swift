import Darwin
import Foundation

public enum ProcessIdentityState: Equatable, Sendable {
    case matching
    case missing
    case reused
    case unknown
}

public protocol ProcessIdentityInspecting: Sendable {
    func identityState(
        pid: Int32,
        waitingSince: Date
    ) -> ProcessIdentityState
}

public struct SystemProcessIdentityInspector: ProcessIdentityInspecting {
    private let timestampTolerance: TimeInterval

    public init(timestampTolerance: TimeInterval = 1) {
        self.timestampTolerance = timestampTolerance
    }

    public func identityState(
        pid: Int32,
        waitingSince: Date
    ) -> ProcessIdentityState {
        guard pid > 0 else { return .unknown }

        if kill(pid, 0) != 0 {
            switch errno {
            case ESRCH:
                return .missing
            case EPERM:
                break
            default:
                return .unknown
            }
        }

        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard result == expectedSize else { return .unknown }

        let startedAt = Date(
            timeIntervalSince1970:
                TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
        if startedAt.timeIntervalSince(waitingSince) > timestampTolerance {
            return .reused
        }
        return .matching
    }
}
