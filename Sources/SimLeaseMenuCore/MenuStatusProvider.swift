import Foundation
import SimLeaseCore

public protocol MenuStatusProviding: Sendable {
    func fetch() async throws -> LeaseStatus
}

public enum MenuStatusError: LocalizedError, Equatable {
    case commandFailed(code: Int32, stderr: String)
    case invalidJSON
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "simlease status failed with exit code \(code)"
                : "simlease status failed with exit code \(code): \(detail)"
        case .invalidJSON:
            return "simlease status returned invalid JSON"
        case .timedOut:
            return "simlease status timed out"
        }
    }
}

private final class StatusProcessBox: @unchecked Sendable {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
}

public actor CLIStatusProvider: MenuStatusProviding {
    private let environment: [String: String]
    private let bundledExecutable: URL?
    private let homeDirectory: URL
    private let timeout: Duration

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledExecutable: URL? = Bundle.main.url(
            forResource: "simlease",
            withExtension: nil,
            subdirectory: "bin"
        ),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeout: Duration = .seconds(10)
    ) {
        self.environment = environment
        self.bundledExecutable = bundledExecutable
        self.homeDirectory = homeDirectory
        self.timeout = timeout
    }

    public func fetch() async throws -> LeaseStatus {
        let box = StatusProcessBox()
        box.process.executableURL = executableURL
        box.process.arguments = ["status", "--json"]
        box.process.standardOutput = box.stdout
        box.process.standardError = box.stderr
        do {
            try box.process.run()
        } catch {
            throw MenuStatusError.commandFailed(code: 127, stderr: "\(error)")
        }
        let timeout = timeout
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: LeaseStatus.self) { group in
                group.addTask { try await self.collectResult(box) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    if box.process.isRunning {
                        box.process.terminate()
                    }
                    throw MenuStatusError.timedOut
                }
                guard let result = try await group.next() else {
                    throw MenuStatusError.invalidJSON
                }
                group.cancelAll()
                return result
            }
        } onCancel: {
            if box.process.isRunning {
                box.process.terminate()
            }
        }
    }

    private func collectResult(_ box: StatusProcessBox) async throws -> LeaseStatus {
        try await withCheckedThrowingContinuation { continuation in
            box.process.terminationHandler = { process in
                process.terminationHandler = nil
                let output = box.stdout.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = box.stderr.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationReason == .exit,
                      process.terminationStatus == 0 else {
                    let code = process.terminationReason == .exit
                        ? process.terminationStatus
                        : 128 + process.terminationStatus
                    continuation.resume(throwing: MenuStatusError.commandFailed(
                        code: code,
                        stderr: String(decoding: errorOutput, as: UTF8.self)
                    ))
                    return
                }
                guard let status = try? JSONDecoder.simLease.decode(
                    LeaseStatus.self,
                    from: output
                ) else {
                    continuation.resume(throwing: MenuStatusError.invalidJSON)
                    return
                }
                continuation.resume(returning: status)
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
            let lanes = [
                LeaseLaneSummary(
                    laneID: "lane-1",
                    slot: 1,
                    project: "AnimAtlas",
                    threadID: "019faaef-c552-7933",
                    threadTitle: "[AnimAtlas] Validate the complete onboarding and camera rescue experience",
                    udid: "UDID-1",
                    deviceTypeName: "iPhone 17 Pro",
                    runtimeName: "iOS 27.0",
                    lastActivityAt: now.addingTimeInterval(-95),
                    recoveryRequired: false
                ),
                LeaseLaneSummary(
                    laneID: "lane-2",
                    slot: 2,
                    project: "Set",
                    threadID: nil,
                    threadTitle: nil,
                    udid: "UDID-2",
                    deviceTypeName: "iPhone 17",
                    runtimeName: "iOS 26.0",
                    lastActivityAt: now.addingTimeInterval(-7_500),
                    recoveryRequired: true
                ),
            ]
            status = LeaseStatus(
                state: .leased,
                owner: owner,
                waiters: waiters,
                lanes: lanes,
                error: nil
            )
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
