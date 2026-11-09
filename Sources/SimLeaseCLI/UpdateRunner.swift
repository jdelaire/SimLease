import Foundation
import SimLeaseCore

public protocol UpdateRunning: Sendable {
    func requestRunningApp() -> Bool
    func run(arguments: [String]) throws -> Int32
}

enum UpdateRunnerError: Error {
    case missingUpdater
}

struct ProcessUpdateRunner: UpdateRunning {
    let updaterURL: URL
    var acknowledgementTimeout: TimeInterval = UpdateSignal.requestLifetime + 1

    func requestRunningApp() -> Bool {
        let center = DistributedNotificationCenter.default()
        let token = UpdateSignal.requestToken()
        let acknowledged = AcknowledgementFlag()
        let observer = center.addObserver(
            forName: UpdateSignal.acknowledge,
            object: token,
            queue: nil
        ) { _ in
            acknowledged.set()
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(
            UpdateSignal.request,
            object: token,
            userInfo: nil,
            deliverImmediately: true
        )
        let deadline = Date().addingTimeInterval(acknowledgementTimeout)
        while !acknowledged.value, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return acknowledged.value
    }

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

private final class AcknowledgementFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledged = false

    var value: Bool {
        lock.withLock { acknowledged }
    }

    func set() {
        lock.withLock { acknowledged = true }
    }
}
