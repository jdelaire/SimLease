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

struct CrashReasonState: Codable {
    var reasons: [String: SimulatorCrashReason] = [:]
    var resolvedThrough: [String: Date] = [:]
}

struct CrashReasonStore {
    let paths: LeasePaths
    var url: URL { paths.root.appendingPathComponent("crash-reasons.json") }

    static func key(deviceID: String, signature: String) -> String { deviceID + ":" + signature }

    func read() throws -> CrashReasonState { try RecoveryFile.read(CrashReasonState.self, at: url) ?? CrashReasonState() }

    func merged(_ state: CrashLoopState, policy: CrashReasonState) -> CrashReasonState {
        var result = policy
        for trigger in state.blocks.values {
            let key = Self.key(deviceID: trigger.deviceID, signature: trigger.signature)
            let report = state.incidents.last { $0.deviceID == trigger.deviceID && $0.signature == trigger.signature }
            let kind = report?.kind ?? (report?.isCriticalSystemService == true || trigger.signature == "simulator-boot-health" ? .criticalInfrastructure : result.reasons[key]?.kind ?? .unknown)
            if trigger.occurredAt >= (result.reasons[key]?.trigger.occurredAt ?? .distantPast) {
                result.reasons[key] = SimulatorCrashReason(trigger: trigger, kind: kind)
            }
        }
        return result
    }

    func active(_ state: CrashLoopState, policy: CrashReasonState) -> [SimulatorCrashReason] {
        merged(state, policy: policy).reasons.filter { key, reason in
            reason.kind != .backgroundService
                && reason.trigger.occurredAt > (state.acknowledgments[reason.trigger.deviceID] ?? .distantPast)
                && reason.trigger.occurredAt > (policy.resolvedThrough[key] ?? .distantPast)
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
