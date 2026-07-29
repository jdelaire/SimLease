import Foundation
import SimLeaseCore

public protocol MenuStatusProviding: Sendable {
    func fetch() async throws -> LeaseStatus
}

public enum MenuStatusError: LocalizedError, Equatable {
    case commandFailed(code: Int32, stderr: String)
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "simlease status failed with exit code \(code)"
                : "simlease status failed with exit code \(code): \(detail)"
        case .invalidJSON:
            return "simlease status returned invalid JSON"
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
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = ["status", "--json"]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let code = process.terminationReason == .exit
                ? process.terminationStatus
                : 128 + process.terminationStatus
            throw MenuStatusError.commandFailed(
                code: code,
                stderr: String(decoding: errorOutput, as: UTF8.self)
            )
        }

        guard let status = try? JSONDecoder.simLease.decode(LeaseStatus.self, from: output) else {
            throw MenuStatusError.invalidJSON
        }
        return status
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
            status = LeaseStatus(state: .leased, owner: owner, waiters: waiters, error: nil)
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
