import Darwin
import Foundation
import SimLeaseCore

enum CoverageDoctor {
    static func run(json: Bool, environment: [String: String], configuration: CLIConfiguration) throws -> Int32 {
        try configuration.inspectCrashes()
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/lib/simlease/shims")
        let commands = ["xcrun", "xcodebuild", "axe", "agent-device"].map { name in
            let executable = try? ExecutableResolver.resolve(
                name: name, path: environment["PATH"] ?? "", excluding: URL(fileURLWithPath: "/dev/null")
            )
            return Command(name: name, path: executable?.path, shimmed: executable?.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        }
        let coordinator = LeaseCoordinator(paths: configuration.paths, store: try MetadataStore(paths: configuration.paths))
        let activity = SimulatorActivityAudit().scan(status: try coordinator.status(), base: configuration.paths)
        let clients = activity.nativeClients ?? []
        let health = try SimLeaseCLI.automaticService(environment: environment, configuration: configuration).status()
        let historical = Set(health.recoveries.filter { $0.state == .history }.map(\.deviceID))
        let blocks = try CrashLoopStore(paths: configuration.paths).read().blocks.values.filter { !historical.contains($0.deviceID) }.sorted { $0.deviceID < $1.deviceID }
        let binding = clients.flatMap { ["--client-pid", String($0.process.pid)] }
        let recipe = NativeRecipe(
            begin: ["simlease", "session", "begin", "--device", "UUID"] + binding + ["--title", "TITLE", "--project", "PROJECT"],
            finish: ["simlease", "session", "finish", "SESSION-ID", "--settled"],
            client: "Wait for ready JSON, call device_open, then use its absolute agent-device launcher with every returned device/config/session flag. Bare PATH commands outside the owner still queue; do not nest another simlease run."
        )
        let slimChecks = slimProfileChecks(environment: environment, configuration: configuration)
        let processes = activity.activities.filter { $0.kind == .unmanaged }.map { ToolProcess(pid: $0.process.pid, executable: $0.tool) }
        let report = Report(commands: commands, unmanagedProcesses: processes, activity: activity, crashBlocks: blocks, simulatorHealth: health, slimProfiles: slimChecks.isEmpty ? nil : slimChecks, nativeSessionRecipe: recipe, limitations: [
            "Absolute executable paths require simlease run; GUI/MCP work requires an explicit native session.",
            "The process audit detects known running tool binaries; it cannot prove that every launch path is coordinated.",
            "Native sessions require explicit external settlement; client exit alone cannot prove daemon work has finished.",
            "Periodic snapshots miss short-lived commands and cannot prove that persistent daemons or capture helpers are idle.",
            "Crash reports can arrive late; crash limits cannot guarantee immediate popup suppression. Healthy boot checks do not prove app crashes fixed.",
        ])
        if json {
            configuration.standardOutput(String(decoding: try JSONEncoder.simLease.encode(report), as: UTF8.self) + "\n")
        } else {
            for command in commands {
                configuration.standardOutput("\(command.name): \(command.path ?? "missing") [\(command.shimmed ? "shimmed" : "BYPASS")]\n")
            }
            for process in processes {
                configuration.standardOutput("Unmanaged PID \(process.pid): \(process.executable)\n")
            }
            for block in blocks {
                let automatic = (health.infrastructureBlocks ?? []).contains(block)
                configuration.standardOutput("Crash blocked: \(block.processName), device \(block.deviceID); \(automatic ? "automatic recovery queued" : "app failure requires a code fix")\n")
            }
            for check in slimChecks where check.state != .ok {
                var line = "Slim profile \(check.state.rawValue): \(check.deviceID)"
                if !check.reenabled.isEmpty { line += "; re-enabled \(check.reenabled.joined(separator: ", "))" }
                if !check.extraDisabled.isEmpty { line += "; also disabled \(check.extraDisabled.joined(separator: ", "))" }
                if [.drift, .incomplete].contains(check.state) { line += "; rerun simlease device slim with the recorded --keep list, or unslim" }
                configuration.standardOutput(line + "\n")
            }
            for recovery in health.recoveries { configuration.standardOutput("Recovery \(recovery.state.rawValue): \(recovery.deviceID), \(recovery.detail)\n") }
            for client in clients {
                configuration.standardOutput("Known GUI/MCP client: \(client.role.rawValue) PID \(client.process.pid), start \(client.process.startMicroseconds) [\(client.bound ? "bound" : "unbound")]\n")
            }
            configuration.standardOutput("Interactive native session:\n\(recipe.begin.joined(separator: " "))\n\(recipe.client)\nAfter native work and capture streams finish:\n\(recipe.finish.joined(separator: " "))\n")
            for item in activity.activities where item.kind != .unmanaged {
                configuration.standardOutput("\(item.kind.rawValue): \(item.tool) PID \(item.process.pid)\n")
            }
            if activity.isIncomplete { configuration.standardOutput("Activity audit incomplete\n") }
            report.limitations.forEach { configuration.standardOutput($0 + "\n") }
        }
        return 0
    }

    private static func slimProfileChecks(environment: [String: String], configuration: CLIConfiguration) -> [SlimProfileCheck] {
        guard let profiles = try? SlimProfileStore(paths: configuration.paths).read(), !profiles.isEmpty else { return [] }
        let manager = SimLeaseCLI.processDeviceManager(environment: environment)
        let devices = configuration.deviceManager ?? manager
        let launchd = (configuration.deviceManager as? any SimulatorLaunchdControlling) ?? manager
        let inventory = (try? devices.inventory()).map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        return profiles.keys.sorted().map { id in
            let device = inventory?[id]
            let disabled = device?.state == "Booted" ? (try? launchd.launchctl(id, ["print-disabled", "system"])).map(SimulatorServiceCatalog.parseDisabled) : nil
            guard let inventory else { return SlimProfileCheck(deviceID: id, state: .unreadable, reenabled: [], extraDisabled: []) }
            return SlimProfileCheck.check(deviceID: id, profile: profiles[id]!, device: inventory[id], disabled: disabled)
        }
    }

    private struct Command: Encodable {
        let name: String
        let path: String?
        let shimmed: Bool
    }

    private struct ToolProcess: Encodable {
        let pid: Int32
        let executable: String
    }

    private struct Report: Encodable {
        let commands: [Command]
        let unmanagedProcesses: [ToolProcess]
        let activity: SimulatorActivityReport
        let crashBlocks: [CrashLoopTrigger]
        let simulatorHealth: SimulatorHealthStatus
        let slimProfiles: [SlimProfileCheck]?
        let nativeSessionRecipe: NativeRecipe
        let limitations: [String]
    }

    private struct NativeRecipe: Encodable {
        let begin: [String]
        let finish: [String]
        let client: String
    }
}
