import Foundation

public enum SimulatorCrashKind: String, Codable, Sendable {
    case application
    case criticalInfrastructure
    case backgroundService
    case unknown
}

public struct SimulatorCrashReason: Codable, Equatable, Sendable {
    public let trigger: CrashLoopTrigger
    public let kind: SimulatorCrashKind
}

struct CrashReasonState: Codable, Equatable {
    var reasons: [String: SimulatorCrashReason] = [:]
    var resolvedThrough: [String: Date] = [:]
}

struct CrashReasonStore {
    let paths: LeasePaths
    var url: URL { paths.root.appendingPathComponent("crash-reasons.json") }

    static func key(deviceID: String, signature: String, kind: SimulatorCrashKind) -> String { deviceID + ":" + signature + ":" + kind.rawValue }

    func read() throws -> CrashReasonState { try RecoveryFile.read(CrashReasonState.self, at: url) ?? CrashReasonState() }

    func merged(_ state: CrashLoopState, policy: CrashReasonState) -> CrashReasonState {
        var result = CrashReasonState()
        for (key, date) in policy.resolvedThrough {
            let resolvedKey = key.hasSuffix(":" + SimulatorCrashKind.criticalInfrastructure.rawValue) ? key : key + ":" + SimulatorCrashKind.criticalInfrastructure.rawValue
            result.resolvedThrough[resolvedKey] = max(result.resolvedThrough[resolvedKey] ?? .distantPast, date)
        }
        for reason in policy.reasons.values {
            let matching = state.incidents.filter { $0.deviceID == reason.trigger.deviceID && $0.signature == reason.trigger.signature && $0.processName == reason.trigger.processName && $0.occurredAt == reason.trigger.occurredAt }
            let proof = matching.last { $0.kind == reason.kind } ?? matching.last { $0.kind != nil }
            let observed = proof?.kind ?? (matching.contains { $0.isCriticalSystemService == true } ? .criticalInfrastructure : reason.kind)
            let kind = observed == .unknown && reason.kind != .unknown ? reason.kind : observed
            let key = Self.key(deviceID: reason.trigger.deviceID, signature: reason.trigger.signature, kind: kind)
            if reason.trigger.occurredAt >= (result.reasons[key]?.trigger.occurredAt ?? .distantPast) {
                result.reasons[key] = SimulatorCrashReason(trigger: reason.trigger, kind: kind)
            }
        }
        for trigger in state.blocks.values {
            let kind = kind(of: trigger, state: state, policy: result)
            let key = Self.key(deviceID: trigger.deviceID, signature: trigger.signature, kind: kind)
            if trigger.occurredAt >= (result.reasons[key]?.trigger.occurredAt ?? .distantPast) {
                result.reasons[key] = SimulatorCrashReason(trigger: trigger, kind: kind)
            }
        }
        return result
    }

    func kind(of trigger: CrashLoopTrigger, state: CrashLoopState, policy: CrashReasonState) -> SimulatorCrashKind {
        let matching = state.incidents.filter { $0.deviceID == trigger.deviceID && $0.signature == trigger.signature && $0.processName == trigger.processName && $0.occurredAt == trigger.occurredAt }
        if let report = matching.last(where: { $0.kind != nil }) { return report.kind! }
        if matching.contains(where: { $0.isCriticalSystemService == true }) || trigger.signature == "simulator-boot-health" { return .criticalInfrastructure }
        return policy.reasons.values.first { $0.trigger == trigger }?.kind ?? .unknown
    }

    func active(_ state: CrashLoopState, policy: CrashReasonState) -> [SimulatorCrashReason] {
        let normalized = merged(state, policy: policy)
        return normalized.reasons.filter { key, reason in
            reason.kind != .backgroundService
                && reason.trigger.occurredAt > (state.acknowledgments[reason.trigger.deviceID] ?? .distantPast)
                && reason.trigger.occurredAt > (normalized.resolvedThrough[key] ?? .distantPast)
        }.map(\.value)
    }

    func blocks(_ state: CrashLoopState, policy: CrashReasonState) -> [String: CrashLoopTrigger] {
        var selected: [String: SimulatorCrashReason] = [:]
        for reason in active(state, policy: policy) {
            let id = reason.trigger.deviceID
            if let current = selected[id] {
                let currentApp = current.kind != .criticalInfrastructure
                let candidateApp = reason.kind != .criticalInfrastructure
                if currentApp && !candidateApp { continue }
                if currentApp == candidateApp && current.trigger.occurredAt > reason.trigger.occurredAt { continue }
            }
            selected[id] = reason
        }
        return selected.mapValues(\.trigger)
    }

    func write(_ policy: CrashReasonState) throws { try RecoveryFile.write(policy, at: url) }
}
