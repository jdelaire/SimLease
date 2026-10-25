import Darwin
import Foundation

public struct LaneConfig: Codable, Equatable, Sendable {
    public var maxLanes: Int

    public init(maxLanes: Int = 1) { self.maxLanes = maxLanes }

    public static func read(_ paths: LeasePaths) -> LaneConfig {
        guard let config = try? RecoveryFile.read(LaneConfig.self, at: paths.config) else { return LaneConfig() }
        return LaneConfig(maxLanes: min(max(config.maxLanes, 1), LeasePaths.maximumLanes))
    }

    public static func write(_ config: LaneConfig, paths: LeasePaths) throws {
        guard (1...LeasePaths.maximumLanes).contains(config.maxLanes) else {
            throw SimulatorTaskError.commandFailed("max lanes must be between 1 and \(LeasePaths.maximumLanes)")
        }
        try SharedStateLock.withLock(paths) { try RecoveryFile.write(config, at: paths.config) }
    }
}

public struct HeadroomSample: Codable, Equatable, Sendable {
    public var memoryFreePercent: Int
    public var compressorBytes: UInt64
    public var swapoutBytes: UInt64
    public var idleTicks: UInt64
    public var totalTicks: UInt64
    public var load: Double
    public var cpus: Int

    public init(memoryFreePercent: Int, compressorBytes: UInt64, swapoutBytes: UInt64, idleTicks: UInt64, totalTicks: UInt64, load: Double, cpus: Int) {
        self.memoryFreePercent = memoryFreePercent
        self.compressorBytes = compressorBytes
        self.swapoutBytes = swapoutBytes
        self.idleTicks = idleTicks
        self.totalTicks = totalTicks
        self.load = load
        self.cpus = cpus
    }

    public static func current() -> HeadroomSample? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        var cpu = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount) }
        }
        guard vmResult == KERN_SUCCESS, cpuResult == KERN_SUCCESS else { return nil }
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) > 0 else { return nil }
        let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3].map(UInt64.init)
        return HeadroomSample(
            memoryFreePercent: Int(level),
            compressorBytes: UInt64(vm.compressor_page_count) * UInt64(getpagesize()),
            swapoutBytes: vm.swapouts &* UInt64(getpagesize()), idleTicks: ticks[2], totalTicks: ticks.reduce(0, +),
            load: load[0], cpus: ProcessInfo.processInfo.activeProcessorCount
        )
    }
}

public struct LaneGateStatus: Codable, Equatable, Sendable {
    public let open: Bool
    public let reason: String?
    public let memoryFreePercent: Int?
    public let cpuIdlePercent: Int?
    public let load: Double?
    public let cpus: Int?

    public init(open: Bool, reason: String?, memoryFreePercent: Int?, cpuIdlePercent: Int?, load: Double? = nil, cpus: Int? = nil) {
        self.load = load
        self.cpus = cpus
        self.open = open
        self.reason = reason
        self.memoryFreePercent = memoryFreePercent
        self.cpuIdlePercent = cpuIdlePercent
    }
}

public struct HeadroomGate: Sendable {
    public static let openFreePercent = 45
    public static let closeFreePercent = 40
    public static let maximumCompressorGrowthPerMinute: Double = 256 * 1_048_576
    public static let maximumSwapoutBytesPerMinute: Double = 64 * 1_048_576
    public static let openCPUIdle = 0.30
    public static let closeCPUIdle = 0.20
    public static let cpuSmoothing = 0.35
    public static let recovery: TimeInterval = 60
    public static let admissionSpacing: TimeInterval = 90
    public static let sampleInterval: TimeInterval = 30

    struct State: Codable, Equatable {
        var sample: HeadroomSample?
        var sampledAt: Date?
        var cpuIdle: Double?
        var compressorGrowth: Double?
        var swapoutGrowth: Double?
        var lastBadAt: Date?
        var reason: String?
        var lastAdmissionAt: Date?
    }

    private let paths: LeasePaths
    private let sampler: @Sendable () -> HeadroomSample?

    public init(paths: LeasePaths, sampler: @escaping @Sendable () -> HeadroomSample? = HeadroomSample.current) {
        self.paths = paths
        self.sampler = sampler
    }

    public func check(now: Date = Date(), ignoreAdmissionSpacing: Bool = false) -> LaneGateStatus {
        (try? SharedStateLock.withLock(paths) {
            var state = (try? RecoveryFile.read(State.self, at: paths.gate)) ?? State()
            let status = Self.evaluate(&state, sample: sampler(), now: now, ignoreAdmissionSpacing: ignoreAdmissionSpacing)
            try? RecoveryFile.write(state, at: paths.gate)
            return status
        }) ?? LaneGateStatus(open: false, reason: "headroom unavailable", memoryFreePercent: nil, cpuIdlePercent: nil)
    }

    public func recordAdmission(now: Date = Date()) {
        _ = try? SharedStateLock.withLock(paths) {
            var state = (try? RecoveryFile.read(State.self, at: paths.gate)) ?? State()
            state.lastAdmissionAt = now
            try RecoveryFile.write(state, at: paths.gate)
        }
    }

    static func evaluate(_ state: inout State, sample: HeadroomSample?, now: Date, ignoreAdmissionSpacing: Bool = false) -> LaneGateStatus {
        guard let sample else {
            state.lastBadAt = now
            state.reason = "headroom unavailable"
            return LaneGateStatus(open: false, reason: state.reason, memoryFreePercent: nil, cpuIdlePercent: nil)
        }
        if let previous = state.sample, let sampledAt = state.sampledAt {
            let elapsed = now.timeIntervalSince(sampledAt)
            if elapsed >= sampleInterval {
                let ticks = Double(sample.totalTicks &- previous.totalTicks)
                if ticks > 0 {
                    let current = Double(sample.idleTicks &- previous.idleTicks) / ticks
                    state.cpuIdle = state.cpuIdle.map { $0 + cpuSmoothing * (current - $0) } ?? current
                }
                state.compressorGrowth = (Double(sample.compressorBytes) - Double(previous.compressorBytes)) / elapsed * 60
                state.swapoutGrowth = Double(sample.swapoutBytes &- previous.swapoutBytes) / elapsed * 60
                state.sample = sample
                state.sampledAt = now
            }
        } else {
            state.sample = sample
            state.sampledAt = now
        }
        let recovered = state.lastBadAt.map { now.timeIntervalSince($0) >= recovery } ?? true
        let threshold = recovered ? closeFreePercent : openFreePercent
        let reason: String? = if sample.memoryFreePercent < threshold {
            "memory \(sample.memoryFreePercent)% free"
        } else if state.cpuIdle == nil {
            "measuring headroom"
        } else if let idle = state.cpuIdle, idle < (recovered ? closeCPUIdle : openCPUIdle) {
            "CPU busy, \(Int(idle * 100))% idle"
        } else if let growth = state.compressorGrowth, growth > maximumCompressorGrowthPerMinute {
            "memory compression growing"
        } else if let growth = state.swapoutGrowth, growth > maximumSwapoutBytesPerMinute {
            "swapping"
        } else {
            nil
        }
        let idlePercent = state.cpuIdle.map { Int($0 * 100) }
        if let reason {
            if state.cpuIdle != nil || sample.memoryFreePercent < threshold {
                state.lastBadAt = now
                state.reason = reason
            }
            return LaneGateStatus(open: false, reason: reason, memoryFreePercent: sample.memoryFreePercent, cpuIdlePercent: idlePercent, load: sample.load, cpus: sample.cpus)
        }
        guard recovered else {
            return LaneGateStatus(open: false, reason: "recovering from \(state.reason ?? "low headroom")", memoryFreePercent: sample.memoryFreePercent, cpuIdlePercent: idlePercent, load: sample.load, cpus: sample.cpus)
        }
        if !ignoreAdmissionSpacing, let admitted = state.lastAdmissionAt, now.timeIntervalSince(admitted) < admissionSpacing {
            return LaneGateStatus(open: false, reason: "spacing admissions", memoryFreePercent: sample.memoryFreePercent, cpuIdlePercent: idlePercent, load: sample.load, cpus: sample.cpus)
        }
        state.reason = nil
        return LaneGateStatus(open: true, reason: nil, memoryFreePercent: sample.memoryFreePercent, cpuIdlePercent: idlePercent, load: sample.load, cpus: sample.cpus)
    }
}
