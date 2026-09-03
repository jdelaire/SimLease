import Foundation
import SimLeaseCore

public protocol MenuCleanupProviding: Sendable {
    func plan() async throws -> CleanupReview
    func apply(id: String) async throws -> CleanupResult
    func apply(
        id: String,
        selectedTargetIDs: Set<String>
    ) async throws -> CleanupResult
}

public enum MenuCleanupError: LocalizedError, Equatable {
    case commandFailed(code: Int32, stderr: String)
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "simlease cleanup failed with exit code \(code)"
                : detail
        case .invalidJSON:
            return "simlease cleanup returned invalid JSON"
        }
    }
}

public actor CLICleanupProvider: MenuCleanupProviding {
    private let explicitExecutable: URL?
    private let environment: [String: String]
    private let bundledExecutable: URL?
    private let homeDirectory: URL
    private let runner: any CleanupCommandRunning

    public init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledExecutable: URL? = Bundle.main.url(
            forResource: "simlease",
            withExtension: nil,
            subdirectory: "bin"
        ),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: any CleanupCommandRunning = ProcessCleanupCommandRunner()
    ) {
        explicitExecutable = executableURL
        self.environment = environment
        self.bundledExecutable = bundledExecutable
        self.homeDirectory = homeDirectory
        self.runner = runner
    }

    public func plan() async throws -> CleanupReview {
        try run(
            arguments: ["clean", "plan", "--json"],
            acceptedCodes: [0],
            as: CleanupReview.self
        )
    }

    public func apply(id: String) async throws -> CleanupResult {
        try await apply(id: id, selectedTargetIDs: [])
    }

    public func apply(
        id: String,
        selectedTargetIDs: Set<String>
    ) async throws -> CleanupResult {
        var arguments = ["clean", "apply", id]
        for targetID in selectedTargetIDs.sorted() {
            arguments.append(contentsOf: ["--target", targetID])
        }
        arguments.append("--json")
        return try run(
            arguments: arguments,
            acceptedCodes: [0, 76],
            as: CleanupResult.self
        )
    }

    private func run<Value: Decodable>(
        arguments: [String],
        acceptedCodes: Set<Int32>,
        as type: Value.Type
    ) throws -> Value {
        let output = try runner.run(
            executable: executableURL,
            arguments: arguments,
            environment: environment
        )
        guard acceptedCodes.contains(output.exitCode) else {
            throw MenuCleanupError.commandFailed(
                code: output.exitCode,
                stderr: output.stderr
            )
        }
        guard let value = try? JSONDecoder.simLease.decode(
            Value.self,
            from: Data(output.stdout.utf8)
        ) else {
            throw MenuCleanupError.invalidJSON
        }
        return value
    }

    private var executableURL: URL {
        if let explicitExecutable {
            return explicitExecutable
        }
#if DEBUG || SIMLEASE_TESTING
        if let path = environment["SIMLEASE_EXECUTABLE_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
#endif
        if let bundledExecutable {
            return bundledExecutable
        }
        return homeDirectory.appending(path: ".local/lib/simlease/simlease")
    }
}

#if DEBUG
public struct PreviewCleanupProvider: MenuCleanupProviding {
    private let review: CleanupReview?
    private let result: CleanupResult?

    public init?(state: String) {
        switch state {
        case "empty":
            review = CleanupReview(
                plan: nil,
                protected: [],
                estimatedBytes: 0
            )
            result = nil
        case "review":
            let fixture = Self.fixture()
            review = fixture.review
            result = fixture.result
        case "partial":
            let fixture = Self.fixture(partial: true)
            review = fixture.review
            result = fixture.result
        case "error":
            review = nil
            result = nil
        default:
            return nil
        }
    }

    public func plan() async throws -> CleanupReview {
        guard let review else { throw PreviewCleanupError() }
        return review
    }

    public func apply(id: String) async throws -> CleanupResult {
        guard let result else { throw PreviewCleanupError() }
        return result
    }

    public func apply(
        id: String,
        selectedTargetIDs: Set<String>
    ) async throws -> CleanupResult {
        guard let result else { throw PreviewCleanupError() }
        return CleanupResult(
            planID: result.planID,
            items: result.items.filter {
                selectedTargetIDs.contains($0.target.identifier)
            },
            estimatedBytes: result.estimatedBytes,
            availableBytesBefore: result.availableBytesBefore,
            availableBytesAfter: result.availableBytesAfter
        )
    }

    private static func fixture(
        partial: Bool = false
    ) -> (review: CleanupReview, result: CleanupResult) {
        let devices = [
            target(.device, "DEVICE-1", "iPhone 17 Pro", 4_000_000_000),
            target(
                .device,
                "DEVICE-2",
                "iPhone 17 Pro Max — long localization and project fixture",
                nil
            ),
            target(.device, "DEVICE-3", "iPad Pro 13-inch", 2_000_000_000),
        ]
        let runtimes = [
            target(.runtime, "RUNTIME-1", "watchOS 26.4", 3_900_000_000),
            target(.runtime, "RUNTIME-2", "iOS 26.5", 8_000_000_000),
        ]
        let reasons: [CleanupProtectionReason] = [
            .booted, .bootedRuntime, .missingLastUsedAt, .notOldEnough, .notOutdated,
        ]
        let protected = reasons.enumerated().map { index, reason in
            ProtectedCleanupTarget(
                target: target(
                    index == 4 ? .runtime : .device,
                    "PROTECTED-\(index)",
                    "Protected simulator \(index + 1)",
                    1_000
                ),
                reason: reason,
                explanation: "Protected: \(reason.rawValue)"
            )
        }
        let now = Date()
        let plan = CleanupPlan(
            id: "ABC123",
            createdAt: now,
            expiresAt: now.addingTimeInterval(600),
            devices: devices,
            runtimes: runtimes,
            protected: protected,
            estimatedBytes: 17_900_000_000,
            availableBytesBefore: 25_000_000_000
        )
        let items = (devices + runtimes).enumerated().map { index, target in
            CleanupItemResult(
                target: target,
                outcome: partial && index == 3
                    ? .skipped
                    : partial && index == 4 ? .failed : .deleted,
                message: partial && index >= 3 ? "Preview safety result" : "Deleted"
            )
        }
        return (
            CleanupReview(
                plan: plan,
                protected: protected,
                estimatedBytes: plan.estimatedBytes
            ),
            CleanupResult(
                planID: plan.id,
                items: items,
                estimatedBytes: plan.estimatedBytes,
                availableBytesBefore: plan.availableBytesBefore,
                availableBytesAfter: 42_900_000_000
            )
        )
    }

    private static func target(
        _ kind: CleanupTargetKind,
        _ id: String,
        _ name: String,
        _ size: Int64?
    ) -> CleanupTarget {
        CleanupTarget(
            kind: kind,
            identifier: id,
            name: name,
            runtimeIdentifier: "preview.runtime.\(id)",
            lastUsedAt: kind == .device
                ? Date().addingTimeInterval(-31 * 24 * 60 * 60)
                : nil,
            sizeBytes: size
        )
    }
}

private struct PreviewCleanupError: LocalizedError {
    var errorDescription: String? { "Preview cleanup error" }
}
#endif
