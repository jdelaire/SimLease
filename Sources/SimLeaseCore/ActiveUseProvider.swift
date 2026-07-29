import Foundation

public protocol ActiveUseProviding: Sendable {
    func activePaths() throws -> [String]
}

public enum ActiveUseError: Error, Equatable {
    case commandFailed(code: Int32, stderr: String)
}

public final class ProcessActiveUseProvider:
    ActiveUseProviding,
    @unchecked Sendable
{
    private let runner: any CleanupCommandRunning
    private let psURL: URL
    private let environment: [String: String]

    public init(
        runner: any CleanupCommandRunning = ProcessCleanupCommandRunner(),
        psURL: URL = URL(fileURLWithPath: "/bin/ps"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.psURL = psURL
        self.environment = environment
    }

    public func activePaths() throws -> [String] {
        let output = try runner.run(
            executable: psURL,
            arguments: ["-axo", "command="],
            environment: environment
        )
        guard output.exitCode == 0 else {
            throw ActiveUseError.commandFailed(
                code: output.exitCode,
                stderr: output.stderr
            )
        }
        return Self.paths(from: output.stdout)
    }

    static func paths(from processList: String) -> [String] {
        let pathFlags: Set<Substring> = [
            "-derivedDataPath",
            "-resultBundlePath",
            "-clonedSourcePackagesDirPath",
            "--scratch-path",
            "--package-path",
        ]
        var paths = Set<String>()
        for line in processList.split(whereSeparator: \.isNewline) {
            let command = String(line)
            guard isBuildCommand(command) else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace)
            for (index, token) in tokens.enumerated() {
                if pathFlags.contains(token), index + 1 < tokens.count {
                    addPath(tokens[index + 1], to: &paths)
                } else if looksLikeProtectedPath(token) {
                    addPath(token, to: &paths)
                }
            }
        }
        return paths.sorted()
    }

    private static func isBuildCommand(_ command: String) -> Bool {
        command.contains("xcodebuild")
            || command.contains("swift-build")
            || (
                command.contains("swift")
                    && (
                        command.contains(" test")
                            || command.contains(" build")
                    )
            )
    }

    private static func looksLikeProtectedPath(_ token: Substring) -> Bool {
        guard token.contains("/") else { return false }
        return token.contains("DerivedData")
            || token.contains("/Previews/")
            || token.contains("iOS DeviceSupport")
            || token.hasSuffix(".xcresult")
            || token.hasSuffix(".xcarchive")
            || token.hasSuffix("/.build")
            || token.hasSuffix(".build")
    }

    private static func addPath(
        _ token: Substring,
        to paths: inout Set<String>
    ) {
        let trimmed = token.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'")
        )
        guard trimmed.hasPrefix("/") else { return }
        paths.insert(
            URL(fileURLWithPath: trimmed)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        )
    }
}
