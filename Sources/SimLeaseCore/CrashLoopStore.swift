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
    private let commitHistory: @Sendable (CrashLoopState) throws -> Void
    private var cancellationURL: URL { paths.root.appendingPathComponent("crash-cancellations.json") }

    public init(paths: LeasePaths) { self.init(paths: paths, commitHistory: nil) }

    init(paths: LeasePaths, commitHistory: (@Sendable (CrashLoopState) throws -> Void)?) {
        self.paths = paths
        let historyURL = paths.root.appendingPathComponent("crash-history.json")
        url = historyURL
        self.commitHistory = commitHistory ?? { try RecoveryFile.write($0, at: historyURL) }
    }

    public func read() throws -> CrashLoopState {
        var state = try rawState()
        let reasons = CrashReasonStore(paths: paths)
        state.blocks = reasons.blocks(state, policy: try reasons.read())
        return state
    }

    private func rawState() throws -> CrashLoopState {
        var state = try RecoveryFile.read(CrashLoopState.self, at: url) ?? CrashLoopState()
        state.incidents = try CrashClassificationStore(paths: paths).overlay(state.incidents)
        return state
    }

    func classifyRetained(_ reports: [SimulatorCrashReport], now: Date) throws {
        guard !reports.isEmpty else { return }
        try SharedStateLock.withLock(paths) { _ = try ingestLocked(reports, now: now, classificationOnly: true) }
    }

    public func reasons() throws -> [SimulatorCrashReason] {
        let store = CrashReasonStore(paths: paths)
        return store.active(try rawState(), policy: try store.read())
    }

    public func resolveInfrastructure(_ expected: SimulatorCrashReason) throws -> Bool {
        guard expected.kind == .criticalInfrastructure else { return false }
        return try SharedStateLock.withLock(paths) {
            var state = try rawState()
            let store = CrashReasonStore(paths: paths)
            var policy = store.merged(state, policy: try store.read())
            let key = CrashReasonStore.key(deviceID: expected.trigger.deviceID, signature: expected.trigger.signature)
            guard store.active(state, policy: policy).contains(expected) else { return false }
            policy.resolvedThrough[key] = expected.trigger.occurredAt
            try store.write(policy)
            state.blocks = store.blocks(state, policy: policy)
            try RecoveryFile.write(state, at: url)
            return true
        }
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
            throw SimulatorTaskError.commandFailed("simulator crash blocked \(id); inspect and fix the crash cause before allowing retries")
        }
    }

    public func shouldCancel(scopeID: String) throws -> Bool {
        try SharedStateLock.withLock(paths) {
            let state = try read()
            let receipts = try RecoveryFile.read([String: [String: CrashLoopTrigger]].self, at: cancellationURL)?[scopeID] ?? [:]
            let policy = try CrashReasonStore(paths: paths).read()
            return receipts.values.contains { receipt in
                let key = CrashReasonStore.key(deviceID: receipt.deviceID, signature: receipt.signature)
                let report = state.incidents.last { $0.deviceID == receipt.deviceID && $0.signature == receipt.signature && $0.occurredAt == receipt.occurredAt && $0.kind != nil }
                return (report?.kind ?? policy.reasons[key]?.kind) != .backgroundService
                    && receipt.occurredAt > (state.acknowledgments[receipt.deviceID] ?? .distantPast)
                    && receipt.occurredAt > (policy.resolvedThrough[key] ?? .distantPast)
            }
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

    private func ingestLocked(_ reports: [SimulatorCrashReport], now: Date, classificationOnly: Bool = false) throws -> [CrashLoopTrigger] {
        var state = try read()
        let reasonStore = CrashReasonStore(paths: paths)
        let savedPolicy = try reasonStore.read()
        var policy = reasonStore.merged(state, policy: savedPolicy)
        let committedIDs = Set(state.incidents.map(\.incidentID))
        var seen = Set(state.incidents.map(\.incidentID))
        var added = [SimulatorCrashReport]()
        func scope(for report: SimulatorCrashReport) -> CrashScope? {
            state.scopes.last {
                $0.deviceIDs.contains(report.deviceID) && report.launchedAt >= $0.startedAt
                    && report.occurredAt >= $0.startedAt && report.occurredAt <= ($0.endedAt ?? now)
            }
        }
        for report in reports.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard classificationOnly || report.occurredAt <= now else { continue }
            if let index = state.incidents.firstIndex(where: { CrashClassificationStore.matches($0, report) }), report.kind != nil {
                state.incidents[index] = report
                let key = CrashReasonStore.key(deviceID: report.deviceID, signature: report.signature)
                if let prior = policy.reasons[key] { policy.reasons[key] = SimulatorCrashReason(trigger: prior.trigger, kind: report.kind!) }
            }
            guard !classificationOnly, report.isCriticalSystemService == true || report.kind == .backgroundService || scope(for: report) != nil,
                  seen.insert(report.incidentID).inserted else { continue }
            state.incidents.append(report)
            added.append(report)
        }
        try CrashClassificationStore(paths: paths).persist(state.incidents.filter { committedIDs.contains($0.incidentID) })
        guard !added.isEmpty else {
            if policy != savedPolicy { try reasonStore.write(policy) }
            return []
        }
        var receipts = try RecoveryFile.read([String: [String: CrashLoopTrigger]].self, at: cancellationURL) ?? [:]
        var receiptsChanged = false
        var triggers = [CrashLoopTrigger]()
        for report in added {
            let key = CrashReasonStore.key(deviceID: report.deviceID, signature: report.signature)
            let kind = report.kind ?? (report.isCriticalSystemService == true ? .criticalInfrastructure : .application)
            if kind == .backgroundService {
                let trigger = CrashLoopTrigger(deviceID: report.deviceID, scopeID: "background-service", processName: report.processName, signature: report.signature, occurredAt: report.occurredAt)
                if trigger.occurredAt >= (policy.reasons[key]?.trigger.occurredAt ?? .distantPast) {
                    policy.reasons[key] = SimulatorCrashReason(trigger: trigger, kind: kind)
                }
                continue
            }
            let acknowledgment = state.acknowledgments[report.deviceID] ?? .distantPast
            guard report.occurredAt > acknowledgment, report.occurredAt > (policy.resolvedThrough[key] ?? .distantPast) else { continue }
            let matches = state.incidents.filter {
                $0.deviceID == report.deviceID && $0.signature == report.signature && $0.occurredAt > acknowledgment
                    && abs($0.occurredAt.timeIntervalSince(report.occurredAt)) <= 120
            }
            guard matches.count >= (report.isCriticalSystemService == true ? 1 : 2) else { continue }
            let newest = matches.max { $0.occurredAt < $1.occurredAt }!
            let trigger = CrashLoopTrigger(deviceID: report.deviceID, scopeID: scope(for: newest)?.id ?? "unowned-system-service", processName: report.processName, signature: report.signature, occurredAt: newest.occurredAt)
            if trigger.occurredAt >= (policy.reasons[key]?.trigger.occurredAt ?? .distantPast) {
                policy.reasons[key] = SimulatorCrashReason(trigger: trigger, kind: kind)
                state.blocks[report.deviceID] = trigger
            }
            guard let receivedScope = scope(for: report) else { continue }
            let cancellation = CrashLoopTrigger(deviceID: report.deviceID, scopeID: receivedScope.id, processName: report.processName, signature: report.signature, occurredAt: report.occurredAt)
            let previous = receipts[receivedScope.id]?[report.deviceID]
            let previousKey = previous.map { CrashReasonStore.key(deviceID: $0.deviceID, signature: $0.signature) }
            let previousKind = previousKey.flatMap { policy.reasons[$0]?.kind } ?? .unknown
            let previousActive = previous.map { $0.occurredAt > acknowledgment && $0.occurredAt > (policy.resolvedThrough[previousKey!] ?? .distantPast) } ?? false
            let previousApp = previousKind != .criticalInfrastructure && previousKind != .backgroundService
            let candidateApp = kind != .criticalInfrastructure
            let replace = !previousActive || (candidateApp && !previousApp) || (candidateApp == previousApp && cancellation.occurredAt > previous!.occurredAt)
            if replace {
                receipts[receivedScope.id, default: [:]][report.deviceID] = cancellation
                receiptsChanged = true
            }
            if !triggers.contains(cancellation) { triggers.append(cancellation) }
        }
        state.incidents = Array(state.incidents.sorted { $0.occurredAt < $1.occurredAt }.suffix(512))
        for (id, values) in receipts {
            let retained = values.filter { _, receipt in policy.reasons[CrashReasonStore.key(deviceID: receipt.deviceID, signature: receipt.signature)]?.kind != .backgroundService }
            if retained.count != values.count { receipts[id] = retained; receiptsChanged = true }
        }
        if receiptsChanged {
            let latest = receipts.sorted { first, second in
                (first.value.values.map(\.occurredAt).max() ?? .distantPast) < (second.value.values.map(\.occurredAt).max() ?? .distantPast)
            }.suffix(256)
            try RecoveryFile.write(Dictionary(uniqueKeysWithValues: latest.map { ($0.key, $0.value) }), at: cancellationURL)
        }
        try reasonStore.write(policy)
        state.blocks = reasonStore.blocks(state, policy: policy)
        try commitHistory(state)
        try CrashClassificationStore(paths: paths).persist(state.incidents)
        return triggers
    }
}
