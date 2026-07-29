import Foundation

public protocol UpdateRunning: Sendable {
    func run(arguments: [String]) throws -> Int32
}

enum UpdateRunnerError: Error {
    case missingUpdater
}

struct ProcessUpdateRunner: UpdateRunning {
    let updaterURL: URL

    func run(arguments: [String]) throws -> Int32 {
        guard FileManager.default.isReadableFile(atPath: updaterURL.path) else {
            throw UpdateRunnerError.missingUpdater
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [updaterURL.path] + arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
