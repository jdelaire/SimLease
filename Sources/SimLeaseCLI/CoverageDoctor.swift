import Darwin
import Foundation
import SimLeaseCore

enum CoverageDoctor {
    static func run(json: Bool, environment: [String: String], configuration: CLIConfiguration) throws -> Int32 {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/lib/simlease/shims")
        let commands = ["xcrun", "xcodebuild", "axe", "agent-device"].map { name in
            let executable = try? ExecutableResolver.resolve(
                name: name, path: environment["PATH"] ?? "", excluding: URL(fileURLWithPath: "/dev/null")
            )
            return Command(name: name, path: executable?.path, shimmed: executable?.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        }
        let journal = try SimulatorTaskStore(paths: configuration.paths).read()
        let output = try ProcessCleanupCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,comm="], environment: environment
        )
        guard output.exitCode == 0 else { throw SimulatorTaskError.commandFailed("process audit failed") }
        let processes = output.stdout.split(separator: "\n").compactMap { line -> ToolProcess? in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int32(parts[0]), pid != getpid() else { return nil }
            let name = URL(fileURLWithPath: String(parts[1])).lastPathComponent
            guard ["xcodebuild", "simctl", "agent-device"].contains(name) else { return nil }
            if journal?.phase == .running, journal?.owner.isAncestor(of: pid) == true { return nil }
            return ToolProcess(pid: pid, executable: String(parts[1]))
        }
        let report = Report(commands: commands, unmanagedProcesses: processes, limitations: [
            "Absolute executable paths and GUI/MCP launches require simlease run or an explicit hold reservation.",
            "The process audit detects known running tool binaries; it cannot prove that every launch path is coordinated.",
            "External daemon work needs native lease and cancellation integration; client exit alone cannot prove it has finished.",
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
            report.limitations.forEach { configuration.standardOutput($0 + "\n") }
        }
        return 0
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
        let limitations: [String]
    }
}
