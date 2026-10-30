import Foundation

public struct SimulatorProcessSample: Codable, Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let startMicroseconds: UInt64
    public let footprintBytes: UInt64
    public let cpuNanoseconds: UInt64

    public init(pid: Int32, parentPID: Int32, name: String, startMicroseconds: UInt64, footprintBytes: UInt64, cpuNanoseconds: UInt64) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.startMicroseconds = startMicroseconds
        self.footprintBytes = footprintBytes
        self.cpuNanoseconds = cpuNanoseconds
    }
}

public struct SimulatorResourceSnapshot: Codable, Equatable, Sendable {
    public let takenAtNanoseconds: UInt64
    public let roots: [String: Int32]
    public let processes: [Int32: SimulatorProcessSample]

    public init(takenAtNanoseconds: UInt64, roots: [String: Int32], processes: [Int32: SimulatorProcessSample]) {
        self.takenAtNanoseconds = takenAtNanoseconds
        self.roots = roots
        self.processes = processes
    }
}

public struct SimulatorResourceUsage: Codable, Equatable, Sendable {
    public let memoryBytes: UInt64
    public let processCount: Int
    public let cpuPercent: Double?

    public init(memoryBytes: UInt64, processCount: Int, cpuPercent: Double?) {
        self.memoryBytes = memoryBytes
        self.processCount = processCount
        self.cpuPercent = cpuPercent
    }
}

public protocol SimulatorResourceSampling: Sendable {
    func snapshot() throws -> SimulatorResourceSnapshot
}

public enum SimulatorResources {
    private static let bootstrapSuffix = "/data/var/run/launchd_bootstrap.plist"

    public static func deviceID(launchdArguments: [String]) -> String? {
        for argument in launchdArguments where argument.lowercased().hasSuffix(bootstrapSuffix) {
            let directory = argument.dropLast(bootstrapSuffix.count)
            guard let component = directory.split(separator: "/").last, let id = UUID(uuidString: String(component)) else { continue }
            return id.uuidString
        }
        return nil
    }

    public static func measure(_ first: SimulatorResourceSnapshot, _ second: SimulatorResourceSnapshot?) -> [String: SimulatorResourceUsage] {
        let current = second ?? first
        let children = childMap(current.processes)
        let elapsed = second.map { Double($0.takenAtNanoseconds) - Double(first.takenAtNanoseconds) } ?? 0
        var result = [String: SimulatorResourceUsage]()
        for (id, root) in current.roots {
            let tree = descendants(of: root, processes: current.processes, children: children)
            guard !tree.isEmpty else { continue }
            var cpu: Double?
            if second != nil, elapsed > 0 {
                var delta: UInt64 = 0
                for process in tree {
                    guard let earlier = first.processes[process.pid], earlier.startMicroseconds == process.startMicroseconds,
                          process.cpuNanoseconds >= earlier.cpuNanoseconds else { continue }
                    delta += process.cpuNanoseconds - earlier.cpuNanoseconds
                }
                cpu = Double(delta) / elapsed * 100
            }
            result[id] = SimulatorResourceUsage(memoryBytes: tree.reduce(0) { $0 + $1.footprintBytes }, processCount: tree.count, cpuPercent: cpu)
        }
        return result
    }

    public static func processes(deviceID: String, in snapshot: SimulatorResourceSnapshot) -> [SimulatorProcessSample] {
        guard let root = snapshot.roots[deviceID] else { return [] }
        return descendants(of: root, processes: snapshot.processes, children: childMap(snapshot.processes))
            .sorted { ($0.footprintBytes, $1.pid) > ($1.footprintBytes, $0.pid) }
    }

    static func childMap(_ processes: [Int32: SimulatorProcessSample]) -> [Int32: [Int32]] {
        var children = [Int32: [Int32]]()
        for process in processes.values where process.parentPID != process.pid { children[process.parentPID, default: []].append(process.pid) }
        return children
    }

    private static func descendants(of root: Int32, processes: [Int32: SimulatorProcessSample], children: [Int32: [Int32]]) -> [SimulatorProcessSample] {
        guard processes[root] != nil else { return [] }
        var seen = Set<Int32>()
        var stack = [root]
        var result = [SimulatorProcessSample]()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted, let process = processes[pid] else { continue }
            result.append(process)
            stack.append(contentsOf: children[pid] ?? [])
        }
        return result
    }
}

public struct SimulatorResourceCache: Sendable {
    private let url: URL

    public init(paths: LeasePaths) {
        url = paths.root.appendingPathComponent("resource-sample.json")
    }

    public func read() -> SimulatorResourceSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SimulatorResourceSnapshot.self, from: data)
    }

    public func write(_ snapshot: SimulatorResourceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
