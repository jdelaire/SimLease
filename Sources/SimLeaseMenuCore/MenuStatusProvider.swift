import Foundation
import SimLeaseCore

public protocol MenuStatusProviding: Sendable {
    func fetch() async throws -> LeaseStatus
    func fetch(includeDevices: Bool) async throws -> LeaseStatus
    func shutdown(deviceIDs: [String]) async throws -> [SimulatorShutdownResult]
}

public extension MenuStatusProviding {
    func fetch(includeDevices: Bool) async throws -> LeaseStatus { try await fetch() }
    func shutdown(deviceIDs: [String]) async throws -> [SimulatorShutdownResult] { throw MenuStatusError.shutdownFailed("unsupported") }
}

public enum MenuStatusError: LocalizedError, Equatable {
    case commandFailed(code: Int32, stderr: String)
    case invalidJSON
    case shutdownFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "simlease status failed with exit code \(code)"
                : "simlease status failed with exit code \(code): \(detail)"
        case .invalidJSON:
            return "simlease status returned invalid JSON"
        case let .shutdownFailed(detail):
            return "Simulator shutdown failed: \(detail)"
        }
    }
}

public actor CLIStatusProvider: MenuStatusProviding {
    private let environment: [String: String]
    private let bundledExecutable: URL?
    private let homeDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledExecutable: URL? = Bundle.main.url(
            forResource: "simlease",
            withExtension: nil,
            subdirectory: "bin"
        ),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.bundledExecutable = bundledExecutable
        self.homeDirectory = homeDirectory
    }

    public func fetch() async throws -> LeaseStatus {
        try await fetch(includeDevices: false)
    }

    public func fetch(includeDevices: Bool) async throws -> LeaseStatus {
        let output = try await run(["status", "--json", "--audit"] + (includeDevices ? ["--devices"] : []))
        guard let status = try? JSONDecoder.simLease.decode(LeaseStatus.self, from: output) else {
            throw MenuStatusError.invalidJSON
        }
        return status
    }

    public func shutdown(deviceIDs: [String]) async throws -> [SimulatorShutdownResult] {
        let (status, output, errors) = try await execute(["device", "shutdown"] + deviceIDs.flatMap { ["--device", $0] })
        if let value = try? JSONDecoder.simLease.decode([String: [SimulatorShutdownResult]].self, from: output), let results = value["results"] {
            return results
        }
        let detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw MenuStatusError.shutdownFailed(detail.isEmpty ? "exit code \(status)" : detail)
    }

    private func run(_ arguments: [String]) async throws -> Data {
        let (status, output, errors) = try await execute(arguments)
        guard status == 0 else {
            throw MenuStatusError.commandFailed(code: status, stderr: String(decoding: errors, as: UTF8.self))
        }
        return output
    }

    private func execute(_ arguments: [String]) async throws -> (Int32, Data, Data) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        async let outputTask = Self.read(stdout.fileHandleForReading)
        async let errorTask = Self.read(stderr.fileHandleForReading)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }

        let output = await outputTask
        let errorOutput = await errorTask
        let code = process.terminationReason == .exit
            ? process.terminationStatus
            : 128 + process.terminationStatus
        return (code, output, errorOutput)
    }

    private static func read(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    private var executableURL: URL {
#if DEBUG || SIMLEASE_TESTING
        if let path = environment["SIMLEASE_EXECUTABLE_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
#endif
        if let bundledExecutable {
            return bundledExecutable
        }
        return homeDirectory
            .appending(path: ".local/lib/simlease/simlease")
    }
}

#if DEBUG
public struct PreviewStatusProvider: MenuStatusProviding {
    private let status: LeaseStatus

    public init?(state: String, now: Date = Date()) {
        switch state {
        case "free":
            status = LeaseStatus(state: .free, owner: nil, waiters: [], error: nil)
        case "leased":
            let owner = LeaseOwner(
                pid: 100,
                acquiredAt: now.addingTimeInterval(-402),
                cwd: "/Users/example/Projects/AnimAtlas",
                project: "AnimAtlas",
                command: [
                    "xcodebuild", "test", "-scheme", "AnimAtlas",
                    "-destination", "platform=iOS Simulator,name=iPhone 17 Pro",
                ],
                source: .codex,
                threadID: "019faaef-c552-7933",
                threadTitle: "[AnimAtlas] Validate the complete onboarding and camera rescue experience"
            )
            let waiters: [LeaseWaiter] = (1...10).map { index -> LeaseWaiter in
                let threadID = String(format: "019f%04d-c552-7933", index)
                let threadTitle: String? = index == 1
                    ? "[Set] Release validation"
                    : nil
                return LeaseWaiter(
                    id: "preview-\(index)",
                    pid: Int32(100 + index),
                    waitingSince: now.addingTimeInterval(Double(index)),
                    cwd: "/Users/example/Projects/Project\(index)",
                    project: "Project\(index)",
                    command: ["xcrun", "simctl", "list"],
                    source: .codex,
                    threadID: threadID,
                    threadTitle: threadTitle
                )
            }
            let devices = [
                SimulatorUsage(id: "5855AB2E-0078-4A4B-9149-780B23A0AA1C", name: "iPhone 17 Pro", runtime: "iOS 27.2", state: "Booted", reservation: .owned),
                SimulatorUsage(id: "D61765E6-0EEC-4D07-83EA-4FB7DD535AB0", name: "iPhone 17", runtime: "iOS 27.2", state: "Booted", reservation: .borrowed),
                SimulatorUsage(id: "0BD66E05-B117-43A2-9483-4E2F2011751F", name: "iPhone Air", runtime: "iOS 27.1", state: "Booted", reservation: .unreserved),
            ]
            status = LeaseStatus(state: .leased, owner: owner, waiters: waiters, error: nil, devices: devices)
        case "error":
            status = LeaseStatus(
                state: .metadataError,
                owner: nil,
                waiters: [],
                error: "owner.json is corrupt"
            )
        default:
            return nil
        }
    }

    public func fetch() async throws -> LeaseStatus { status }
}
#endif
