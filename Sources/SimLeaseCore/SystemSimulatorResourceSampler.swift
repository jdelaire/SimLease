import Darwin
import Foundation

public struct SystemSimulatorResourceSampler: SimulatorResourceSampling {
    public init() {}

    public func snapshot() throws -> SimulatorResourceSnapshot {
        var buffer = [Int32](repeating: 0, count: 32_768)
        let bytes = buffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, bytes < buffer.count * MemoryLayout<Int32>.size else {
            throw ChildProcessError.systemCall("proc_listpids", errno)
        }
        let takenAt = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        var parents = [Int32: (parent: Int32, name: String, start: UInt64)]()
        var roots = [String: Int32]()
        for pid in buffer.prefix(Int(bytes) / MemoryLayout<Int32>.size) where pid > 0 {
            guard let info = ProcessReference.info(pid: pid), info.pbi_status != 5 else { continue }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            parents[pid] = (Int32(info.pbi_ppid), name, info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
            if name == "launchd_sim", let arguments = try? SystemSimulatorProcessReader.parseArguments(SystemSimulatorProcessReader.procargs(pid: pid)).arguments,
               let id = SimulatorResources.deviceID(launchdArguments: arguments) {
                roots[id] = pid
            }
        }
        var children = [Int32: [Int32]]()
        for (pid, entry) in parents where entry.parent != pid { children[entry.parent, default: []].append(pid) }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var processes = [Int32: SimulatorProcessSample]()
        var stack = Array(roots.values)
        while let pid = stack.popLast() {
            guard processes[pid] == nil, let entry = parents[pid], let usage = Self.usage(pid: pid) else { continue }
            let ticks = usage.ri_user_time + usage.ri_system_time
            processes[pid] = SimulatorProcessSample(
                pid: pid, parentPID: entry.parent, name: entry.name, startMicroseconds: entry.start,
                footprintBytes: usage.ri_phys_footprint,
                cpuNanoseconds: ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(max(timebase.denom, 1))
            )
            stack.append(contentsOf: children[pid] ?? [])
        }
        return SimulatorResourceSnapshot(takenAtNanoseconds: takenAt, roots: roots, processes: processes)
    }

    private static func usage(pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info : nil
    }
}
