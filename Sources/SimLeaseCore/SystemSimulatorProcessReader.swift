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
            else if !hasExited(pid: pid) { inventory.uninspectedProcessCount += 1 }
        }
        return SimulatorProcessInventory(references: references, uninspectedProcessCount: inventory.uninspectedProcessCount)
    }

    func current(pid: Int32) -> ProcessReference? { ProcessReference.capture(pid: pid) }

    func hasExited(pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

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
        guard count > 0 else { throw ChildProcessError.systemCall("proc_pidpath", errno) }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        return SimulatorProcessSnapshot(
            process: reference, parentPID: Int32(info.pbi_ppid), executable: executable,
            arguments: Self.isCandidate(tool) ? try arguments(pid: reference.pid) : []
        )
    }

    static func isNode(_ name: String) -> Bool {
        ["node", "nodejs", "Electron"].contains(name) || name.hasPrefix("T3 Code")
    }

    private static func isCandidate(_ name: String) -> Bool {
        ["simctl", "xcrun", "xcodebuild", "axe", "agent-device"].contains(name) || isNode(name)
    }

    private func arguments(pid: Int32) throws -> [String] {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: 262_144)
        var size = buffer.count
        let result = query.withUnsafeMutableBufferPointer { query in
            buffer.withUnsafeMutableBytes { sysctl(query.baseAddress, UInt32(query.count), $0.baseAddress, &size, nil, 0) }
        }
        guard result == 0, size >= 4 else { throw ChildProcessError.systemCall("procargs", errno) }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { throw ChildProcessError.systemCall("procargs", EINVAL) }
        var index = 4
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var arguments = [String]()
        for _ in 0..<argc {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            guard index < size else { throw ChildProcessError.systemCall("procargs", EINVAL) }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
