import Darwin
import Foundation

struct SystemSimulatorProcessReader: SimulatorProcessReading {
    func references() throws -> SimulatorProcessInventory {
        var buffer = [Int32](repeating: 0, count: 32_768)
        errno = 0
        let bytes = buffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, bytes < buffer.count * MemoryLayout<Int32>.size else {
            throw ChildProcessError.systemCall("proc_listpids", errno)
        }
        var inventory = SimulatorProcessInventory(references: [])
        var references = [ProcessReference]()
        for pid in buffer.prefix(Int(bytes) / MemoryLayout<Int32>.size) where pid > 0 {
            if let reference = ProcessReference.capture(pid: pid) { references.append(reference) }
            else if !hasExited(pid: pid), !Self.isZombie(pid: pid) { inventory.uninspectedProcessCount += 1 }
        }
        return SimulatorProcessInventory(references: references, uninspectedProcessCount: inventory.uninspectedProcessCount)
    }

    func current(pid: Int32) -> ProcessReference? { ProcessReference.capture(pid: pid) }

    func hasExited(pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

    static func isZombie(pid: Int32) -> Bool {
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = query.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), &process, &size, nil, 0) }
        return result == 0 && size == MemoryLayout<kinfo_proc>.size && process.kp_proc.p_pid == pid && process.kp_proc.p_stat == SZOMB
    }

    func details(for reference: ProcessReference) throws -> SimulatorProcessSnapshot {
        guard let info = ProcessReference.info(pid: reference.pid) else {
            throw SimulatorTaskError.unverifiedProcess(reference.pid)
        }
        let name = withUnsafeBytes(of: info.pbi_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard Self.isCandidate(name), info.pbi_status != 5 else {
            return SimulatorProcessSnapshot(process: reference, parentPID: Int32(info.pbi_ppid), executable: info.pbi_status == 5 ? "" : name, arguments: [])
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(reference.pid, $0.baseAddress, UInt32($0.count)) }
        let executable: String
        if count > 0 {
            executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else {
            let failure = errno
            guard failure == ENOENT else { throw ChildProcessError.systemCall("proc_pidpath", failure) }
            executable = try Self.parseArguments(try Self.procargs(pid: reference.pid)).executable
        }
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        return SimulatorProcessSnapshot(
            process: reference, parentPID: Int32(info.pbi_ppid), executable: executable,
            arguments: Self.isCandidate(tool) ? try Self.parseArguments(try Self.procargs(pid: reference.pid)).arguments : []
        )
    }

    static func isNode(_ name: String) -> Bool {
        ["node", "nodejs", "Electron"].contains(name) || name.hasPrefix("T3 Code")
    }

    private static func isCandidate(_ name: String) -> Bool {
        ["simctl", "xcrun", "xcodebuild", "axe", "agent-device"].contains(name) || isNode(name)
    }

    static func procargs(pid: Int32) throws -> [UInt8] {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: 262_144)
        var size = buffer.count
        let result = query.withUnsafeMutableBufferPointer { query in
            buffer.withUnsafeMutableBytes { sysctl(query.baseAddress, UInt32(query.count), $0.baseAddress, &size, nil, 0) }
        }
        guard result == 0, size >= 4 else { throw ChildProcessError.systemCall("procargs", errno) }
        return Array(buffer.prefix(size))
    }

    static func parseArguments(_ buffer: [UInt8]) throws -> (executable: String, arguments: [String]) {
        let size = buffer.count
        guard size >= 4 else { throw ChildProcessError.systemCall("procargs", EINVAL) }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { throw ChildProcessError.systemCall("procargs", EINVAL) }
        var index = 4
        while index < size && buffer[index] != 0 { index += 1 }
        let executable = String(decoding: buffer[4..<index], as: UTF8.self)
        guard !executable.isEmpty else { throw ChildProcessError.systemCall("procargs", EINVAL) }
        while index < size && buffer[index] == 0 { index += 1 }
        var arguments = [String]()
        for _ in 0..<argc {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            guard index < size else { throw ChildProcessError.systemCall("procargs", EINVAL) }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return (executable, arguments)
    }
}
