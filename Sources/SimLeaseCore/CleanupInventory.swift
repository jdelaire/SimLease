import Foundation

public struct CleanupDeviceRecord: Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let runtimeIdentifier: String
    public let state: String
    public let lastUsedAt: Date?
    public let dataPath: String?
    public let sizeBytes: Int64?

    public init(
        identifier: String,
        name: String,
        runtimeIdentifier: String,
        state: String,
        lastUsedAt: Date?,
        dataPath: String?,
        sizeBytes: Int64?
    ) {
        self.identifier = identifier
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.state = state
        self.lastUsedAt = lastUsedAt
        self.dataPath = dataPath
        self.sizeBytes = sizeBytes
    }
}

public struct CleanupRuntimeRecord: Equatable, Sendable {
    public let identifier: String
    public let runtimeIdentifier: String
    public let name: String
    public let build: String
    public let sizeBytes: Int64?

    public init(
        identifier: String,
        runtimeIdentifier: String,
        name: String,
        build: String,
        sizeBytes: Int64?
    ) {
        self.identifier = identifier
        self.runtimeIdentifier = runtimeIdentifier
        self.name = name
        self.build = build
        self.sizeBytes = sizeBytes
    }
}

public struct CleanupInventory: Equatable, Sendable {
    public let devices: [CleanupDeviceRecord]
    public let runtimes: [CleanupRuntimeRecord]
    public let outdatedRuntimeIDs: Set<String>
    public let hasActiveXcodeTests: Bool
    public let availableBytes: Int64?

    public init(
        devices: [CleanupDeviceRecord],
        runtimes: [CleanupRuntimeRecord],
        outdatedRuntimeIDs: Set<String>,
        hasActiveXcodeTests: Bool,
        availableBytes: Int64?
    ) {
        self.devices = devices
        self.runtimes = runtimes
        self.outdatedRuntimeIDs = outdatedRuntimeIDs
        self.hasActiveXcodeTests = hasActiveXcodeTests
        self.availableBytes = availableBytes
    }
}

public enum CleanupInventoryError: Error, Equatable {
    case commandFailed(arguments: [String], code: Int32, stderr: String)
    case invalidDevicesJSON
    case invalidRuntimesJSON
    case invalidRuntimeDryRun
}

enum CleanupInventoryParser {
    static func decodeDevices(from data: Data) throws -> [CleanupDeviceRecord] {
        struct Envelope: Decodable {
            let devices: [String: [Device]]
        }
        struct Device: Decodable {
            let dataPath: String?
            let dataPathSize: Int64?
            let udid: String
            let lastUsedAt: Date?
            let state: String
            let name: String
        }

        guard let envelope = try? JSONDecoder.simLease.decode(Envelope.self, from: data)
        else {
            throw CleanupInventoryError.invalidDevicesJSON
        }
        return envelope.devices.flatMap { runtimeIdentifier, devices in
            devices.map {
                CleanupDeviceRecord(
                    identifier: $0.udid,
                    name: $0.name,
                    runtimeIdentifier: runtimeIdentifier,
                    state: $0.state,
                    lastUsedAt: $0.lastUsedAt,
                    dataPath: $0.dataPath,
                    sizeBytes: $0.dataPathSize
                )
            }
        }
    }

    static func decodeRuntimes(from data: Data) throws -> [CleanupRuntimeRecord] {
        struct Runtime: Decodable {
            let build: String
            let identifier: String
            let runtimeIdentifier: String
            let sizeBytes: Int64?
            let version: String
        }

        guard let decoded = try? JSONDecoder.simLease.decode(
            [String: Runtime].self,
            from: data
        ) else {
            throw CleanupInventoryError.invalidRuntimesJSON
        }
        return decoded.values.map {
            CleanupRuntimeRecord(
                identifier: $0.identifier,
                runtimeIdentifier: $0.runtimeIdentifier,
                name: "\($0.runtimeIdentifier) \($0.version)",
                build: $0.build,
                sizeBytes: $0.sizeBytes
            )
        }
    }

    static func decodeOutdatedRuntimeIDs(
        from output: String,
        runtimes: [CleanupRuntimeRecord]
    ) throws -> Set<String> {
        if output.trimmingCharacters(in: .whitespacesAndNewlines)
            == "No matching images found to delete"
        {
            return []
        }
        let known = Set(runtimes.map(\.identifier))
        var result = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.localizedCaseInsensitiveContains("would delete") else {
                throw CleanupInventoryError.invalidRuntimeDryRun
            }
            let tokens = text.components(
                separatedBy: CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "-"))
                    .inverted
            )
            let matches = Set(tokens).intersection(known)
            guard matches.count == 1, let match = matches.first else {
                throw CleanupInventoryError.invalidRuntimeDryRun
            }
            result.insert(match)
        }
        return result
    }
}

public protocol CleanupInventoryProviding: Sendable {
    func inventory() throws -> CleanupInventory
    func deleteDevice(id: String) throws
    func deleteRuntime(id: String) throws
}

public final class ProcessCleanupInventoryProvider:
    CleanupInventoryProviding,
    @unchecked Sendable
{
    private let runner: any CleanupCommandRunning
    private let xcrunURL: URL
    private let psURL: URL
    private let environment: [String: String]
    private let capacityURL: URL

    public init(
        runner: any CleanupCommandRunning = ProcessCleanupCommandRunner(),
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        psURL: URL = URL(fileURLWithPath: "/bin/ps"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        capacityURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.runner = runner
        self.xcrunURL = xcrunURL
        self.psURL = psURL
        self.environment = environment
        self.capacityURL = capacityURL
    }

    public func inventory() throws -> CleanupInventory {
        let devicesOutput = try runXcrun(["simctl", "list", "devices", "-j"])
        let runtimesOutput = try runXcrun(["simctl", "runtime", "list", "-j"])
        let runtimes = try CleanupInventoryParser.decodeRuntimes(
            from: Data(runtimesOutput.stdout.utf8)
        )
        let dryRunOutput = try runOutdatedRuntimeDryRun()
        let processOutput = try run(
            executable: psURL,
            arguments: ["-axo", "command="],
            environment: environment
        )
        return CleanupInventory(
            devices: try CleanupInventoryParser.decodeDevices(
                from: Data(devicesOutput.stdout.utf8)
            ),
            runtimes: runtimes,
            outdatedRuntimeIDs: try CleanupInventoryParser.decodeOutdatedRuntimeIDs(
                from: dryRunOutput.stdout,
                runtimes: runtimes
            ),
            hasActiveXcodeTests: Self.hasActiveTests(processOutput.stdout),
            availableBytes: try? capacityURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
        )
    }

    public func deleteDevice(id: String) throws {
        _ = try runXcrun(["simctl", "delete", id])
    }

    public func deleteRuntime(id: String) throws {
        _ = try runXcrun(["simctl", "runtime", "delete", id])
    }

    private func runXcrun(_ arguments: [String]) throws -> CleanupCommandOutput {
        var childEnvironment = environment
        childEnvironment["SIMLEASE_HELD"] = "1"
        return try run(
            executable: xcrunURL,
            arguments: arguments,
            environment: childEnvironment
        )
    }

    private func runOutdatedRuntimeDryRun() throws -> CleanupCommandOutput {
        let arguments = [
            "simctl", "runtime", "delete", "--outdated", "--dry-run",
        ]
        var childEnvironment = environment
        childEnvironment["SIMLEASE_HELD"] = "1"
        let output = try runner.run(
            executable: xcrunURL,
            arguments: arguments,
            environment: childEnvironment
        )
        if output.exitCode == 2,
           output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            == "No matching images found to delete"
        {
            return CleanupCommandOutput(
                exitCode: 0,
                stdout: output.stderr,
                stderr: ""
            )
        }
        guard output.exitCode == 0 else {
            throw CleanupInventoryError.commandFailed(
                arguments: arguments,
                code: output.exitCode,
                stderr: output.stderr
            )
        }
        return output
    }

    private func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> CleanupCommandOutput {
        let output = try runner.run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        guard output.exitCode == 0 else {
            throw CleanupInventoryError.commandFailed(
                arguments: arguments,
                code: output.exitCode,
                stderr: output.stderr
            )
        }
        return output
    }

    private static func hasActiveTests(_ processList: String) -> Bool {
        processList.split(whereSeparator: \.isNewline).contains { line in
            let command = String(line)
            guard command.contains("xcodebuild") else { return false }
            return command.contains(" test")
                || command.contains("test-without-building")
                || command.contains("build-for-testing")
        }
    }
}
