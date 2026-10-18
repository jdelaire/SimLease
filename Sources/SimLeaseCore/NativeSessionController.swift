import Darwin
import Foundation

public struct NativeSessionController: Sendable {
    private let paths: LeasePaths
    private let tasks: SimulatorTaskService

    public init(paths: LeasePaths, tasks: SimulatorTaskService) {
        self.paths = paths
        self.tasks = tasks
    }

    public func finish(id: String, identity: LeaseIdentity, timeout: TimeInterval = 120) throws {
        let store = SimulatorTaskStore(paths: paths)
        guard let record = try store.read(), record.externalSessionID == id else {
            throw SimulatorTaskError.commandFailed("native session not found")
        }
        let gate = try NativeAdmissionGate(paths: paths, exclusive: true, timeout: timeout)
        defer { withExtendedLifetime(gate) {} }
        guard let active = try store.read(), active.token == record.token else {
            throw SimulatorTaskError.commandFailed("native session changed before settlement")
        }
        guard record.owner.state != .unknown else { throw SimulatorTaskError.unverifiedProcess(record.owner.pid) }
        try NativeSettlementStore(paths: paths).acknowledge(record)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            guard let current = try store.read(), current.token == record.token else { return }
            switch current.owner.state {
            case .missing, .reused:
                do { try tasks.recover(identity: identity) }
                catch {
                    if try store.read()?.token != record.token { return }
                    throw error
                }
            case .matching:
                if current.phase == .quarantined {
                    throw SimulatorTaskError.unfinishedTask(current.failure ?? "native cleanup failed")
                }
            case .unknown:
                throw SimulatorTaskError.unverifiedProcess(current.owner.pid)
            }
            guard Date() < deadline else { throw SimulatorTaskError.commandTimedOut("native session cleanup") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    public static func waitForAcknowledgment(paths: LeasePaths, id: String, environment: [String: String]) throws -> Int32 {
        let store = SimulatorTaskStore(paths: paths)
        guard try store.authorizesNestedCommand(environment: environment, pid: getpid()),
              let record = try store.read(), record.externalSessionID == id,
              record.child == (try ProcessReference.current())
        else { throw SimulatorTaskError.commandFailed("native waiter requires its journaled child identity") }
        let settlements = NativeSettlementStore(paths: paths)
        while true {
            if try settlements.isAcknowledged(record) { return 0 }
            guard record.owner.state == .matching, try store.read()?.token == record.token else { return 74 }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
