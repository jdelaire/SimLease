import Darwin
import Foundation
import SimLeaseCore

extension SimLeaseCLI {
    static func runStatus(
        json: Bool,
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let coordinator = try makeCoordinator(configuration: configuration)
        let status = try coordinator.status()
        if json {
            let data = try JSONEncoder.simLease.encode(status)
            configuration.standardOutput(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            configuration.standardOutput("\(status.state.rawValue)\n")
        }
        return 0
    }

    static func runWait(
        timeout: Double,
        json: Bool,
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let coordinator = try makeCoordinator(configuration: configuration)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let status = try coordinator.status()
            switch status.state {
            case .free:
                if json {
                    try writeJSON(status, configuration: configuration)
                } else {
                    configuration.standardOutput("free\n")
                }
                return 0
            case .metadataError:
                if json {
                    try writeJSON(status, configuration: configuration)
                } else {
                    configuration.standardError(
                        "SimLease: simulator metadata error: \(status.error ?? "unknown error")\n"
                    )
                }
                return 74
            case .leased:
                let remaining = deadline.timeIntervalSince(Date())
                if remaining <= 0 {
                    if json {
                        try writeJSON(status, configuration: configuration)
                    } else {
                        configuration.standardError(busyMessage(status))
                    }
                    return 75
                }
                if !json, let owner = status.owner {
                    configuration.standardError(
                        "SimLease: waiting; owner \(ownerSummary(owner))\n"
                    )
                }
                Thread.sleep(forTimeInterval: min(0.5, remaining))
            }
        }
    }

    static func runName(
        title: String,
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        guard let threadID = environment["CODEX_THREAD_ID"] else {
            throw CommandParserError.usage
        }
        let store = try MetadataStore(paths: configuration.paths)
        try store.registerThreadName(id: threadID, title: title)
        return 0
    }

    static func runHold(
        title: String,
        project: String,
        arguments: [String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let store = try MetadataStore(paths: configuration.paths)
        let coordinator = LeaseCoordinator(
            paths: configuration.paths,
            store: store,
            timing: configuration.timing
        )
        let cwd = FileManager.default.currentDirectoryPath
        let identity = LeaseIdentity(
            pid: getpid(),
            cwd: cwd,
            project: project,
            command: arguments,
            source: .manualXcode,
            threadID: nil,
            threadTitle: title
        )
        let signals = SignalLatch()
        let handle = try coordinator.acquire(
            identity: identity,
            onWaitReport: waitReporter(configuration.standardError),
            cancellationSignal: { signals.current }
        )
        defer { handle.release() }
        let laneStore = try LaneStore(paths: configuration.paths)
        let laneState = try laneStore.readState()
        let highestReservedSlot = laneState.reservations.map(\.slot).max() ?? 0
        let laneHandle = try LaneLockCoordinator(
            paths: configuration.paths,
            timing: configuration.timing
        ).acquireAll(maxSlot: max(
            laneState.configuration.maxActive,
            highestReservedSlot
        ))
        configuration.standardOutput("SimLease: acquired for \(title) (\(project)); press Ctrl-C to release\n")
        while signals.current == nil {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let signal = signals.current ?? SIGINT
        laneHandle.release()
        return 128 + signal
    }

    private static func makeCoordinator(
        configuration: CLIConfiguration
    ) throws -> LeaseCoordinator {
        let store = try MetadataStore(paths: configuration.paths)
        let lanes = try? LaneStore(paths: configuration.paths)
        return LeaseCoordinator(
            paths: configuration.paths,
            store: store,
            laneStore: lanes,
            timing: configuration.timing
        )
    }

    static func waitReporter(
        _ output: @escaping @Sendable (String) -> Void
    ) -> @Sendable (LeaseStatus) -> Void {
        { status in
            guard let owner = status.owner else {
                output("SimLease: waiting; owner metadata unavailable\n")
                return
            }
            output("SimLease: waiting; owner \(ownerSummary(owner))\n")
        }
    }

    static func busyMessage(_ status: LeaseStatus) -> String {
        guard let owner = status.owner else {
            return "SimLease: simulator lease busy; owner metadata unavailable\n"
        }
        let name = owner.threadTitle
            ?? owner.threadID.map { String($0.prefix(8)) }
            ?? "\(sourceLabel(owner.source)) · \(owner.project)"
        return "SimLease: simulator lease busy; owner \(name) (\(owner.project))\n"
    }

    private static func ownerSummary(_ owner: LeaseOwner) -> String {
        let name = owner.threadTitle
            ?? owner.threadID.map { String($0.prefix(8)) }
            ?? "\(sourceLabel(owner.source)) · \(owner.project)"
        let held = elapsedString(since: owner.acquiredAt)
        return "\(name) (\(owner.project)), held \(held)"
    }

    private static func sourceLabel(_ source: LeaseSource) -> String {
        switch source {
        case .codex: "Codex"
        case .terminal: "Terminal"
        case .manualXcode: "Manual Xcode"
        }
    }

    private static func elapsedString(since date: Date) -> String {
        let total = max(0, Int(Date().timeIntervalSince(date)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
