import Foundation

public struct CrashScope: Codable, Equatable, Sendable {
    public let id: String
    public let deviceIDs: [String]
    public let startedAt: Date
    public var endedAt: Date?
}

public struct CrashLoopTrigger: Codable, Equatable, Sendable {
    public let deviceID: String
    public let scopeID: String
    public let processName: String
    public let signature: String
    public let occurredAt: Date
}

public struct CrashLoopState: Codable, Sendable {
    public var scopes = [CrashScope]()
    public var incidents = [SimulatorCrashReport]()
    public var blocks = [String: CrashLoopTrigger]()
    public var acknowledgments = [String: Date]()
}

public struct CrashLoopStore: Sendable {
    private let url: URL
    private let paths: LeasePaths

    public init(paths: LeasePaths) {
        self.paths = paths
        url = paths.root.appendingPathComponent("crash-history.json")
    }

    public func read() throws -> CrashLoopState {
        try RecoveryFile.read(CrashLoopState.self, at: url) ?? CrashLoopState()
    }

    public func beginScope(id: String, deviceIDs: [String], startedAt: Date) throws {
        try SharedStateLock.withLock(paths) {
            var state = try read()
            state.scopes.append(CrashScope(id: id, deviceIDs: deviceIDs, startedAt: startedAt))
            state.scopes = Array(state.scopes.suffix(256))
            try RecoveryFile.write(state, at: url)
        }
    }

    public func endScope(id: String, endedAt: Date) throws {
        try SharedStateLock.withLock(paths) {
            var state = try read()
            if let index = state.scopes.firstIndex(where: { $0.id == id }) {
                state.scopes[index].endedAt = endedAt
                try RecoveryFile.write(state, at: url)
            }
        }
    }

    public func requireHealthy(_ deviceIDs: [String]) throws {
        let state = try read()
        for id in deviceIDs where state.blocks[id] != nil {
            throw SimulatorTaskError.commandFailed("repeated simulator crashes blocked \(id); inspect the crash cause, then use simlease device repair --device \(id) --acknowledge-crashes")
        }
    }

    public static func permitsCleanup(_ invocation: [String]) -> Bool {
        guard let executable = invocation.first else { return false }
        var tool = URL(fileURLWithPath: executable).lastPathComponent
        var arguments = Array(invocation.dropFirst())
        if tool == "xcrun", let selected = ProtectedCommand.selectedXcrunTool(in: arguments), let index = arguments.firstIndex(of: selected) {
            tool = selected
            arguments = Array(arguments.dropFirst(index + 1))
        }
        if tool == "xcodebuild" { return NativeClientAdmission.isPureXcodebuildQuery(arguments) }
        return tool == "simctl" && arguments.first.map { ["list", "help", "--help", "--version", "getenv", "get_app_container", "get_app_info", "listapps", "terminate", "shutdown"].contains($0) } == true
    }

    public func acknowledge(deviceID: String, at date: Date) throws {
        try SharedStateLock.withLock(paths) {
            var state = try read()
            state.blocks.removeValue(forKey: deviceID)
            state.acknowledgments[deviceID] = date
            try RecoveryFile.write(state, at: url)
        }
    }

    public func blockInfrastructureFailure(deviceID: String) throws {
        try SharedStateLock.withLock(paths) {
            var state = try read()
            if state.blocks[deviceID] == nil {
                state.blocks[deviceID] = CrashLoopTrigger(deviceID: deviceID, scopeID: "device-repair", processName: "Simulator boot", signature: "simulator-boot-health", occurredAt: Date())
                try RecoveryFile.write(state, at: url)
            }
        }
    }

    public func ingest(_ reports: [SimulatorCrashReport], now: Date) throws -> [CrashLoopTrigger] {
        guard !reports.isEmpty else { return [] }
        return try SharedStateLock.withLock(paths) { try ingestLocked(reports, now: now) }
    }

    private func ingestLocked(_ reports: [SimulatorCrashReport], now: Date) throws -> [CrashLoopTrigger] {
        var state = try read()
        var seen = Set(state.incidents.map(\.incidentID))
        var added = [SimulatorCrashReport]()
        func scope(for report: SimulatorCrashReport) -> CrashScope? {
            state.scopes.last {
                $0.deviceIDs.contains(report.deviceID) && report.launchedAt >= $0.startedAt
                    && report.occurredAt >= $0.startedAt && report.occurredAt <= ($0.endedAt ?? now)
            }
        }
        for report in reports.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard report.occurredAt <= now, scope(for: report) != nil, seen.insert(report.incidentID).inserted else { continue }
            state.incidents.append(report)
            added.append(report)
        }
        var triggers = [CrashLoopTrigger]()
        for report in added {
            let acknowledgment = state.acknowledgments[report.deviceID] ?? .distantPast
            guard report.occurredAt > acknowledgment, let receivedScope = scope(for: report) else { continue }
            let matches = state.incidents.filter {
                $0.deviceID == report.deviceID && $0.signature == report.signature && $0.occurredAt > acknowledgment
                    && abs($0.occurredAt.timeIntervalSince(report.occurredAt)) <= 120
            }
            guard matches.count >= 2 else { continue }
            let newest = matches.max { $0.occurredAt < $1.occurredAt }!
            guard let newestOwner = scope(for: newest) else { continue }
            let trigger = CrashLoopTrigger(deviceID: report.deviceID, scopeID: newestOwner.id, processName: report.processName, signature: report.signature, occurredAt: newest.occurredAt)
            if state.blocks[report.deviceID] != trigger {
                state.blocks[report.deviceID] = trigger
            }
            let cancellation = CrashLoopTrigger(deviceID: report.deviceID, scopeID: receivedScope.id, processName: report.processName, signature: report.signature, occurredAt: report.occurredAt)
            if !triggers.contains(cancellation) { triggers.append(cancellation) }
        }
        state.incidents = Array(state.incidents.sorted { $0.occurredAt < $1.occurredAt }.suffix(512))
        try RecoveryFile.write(state, at: url)
        return triggers
    }
}
