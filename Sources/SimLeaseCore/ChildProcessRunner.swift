import Foundation
import Dispatch
import Darwin

public struct ChildResult: Equatable, Sendable {
    public let exitCode: Int32

    public init(exitCode: Int32) {
        self.exitCode = exitCode
    }
}

public enum ChildProcessError: Error, Equatable {
    case systemCall(String, Int32)
}

public enum ChildProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> ChildResult {
        var childPID: pid_t = 0
        let argv = [executable.path] + arguments
        let envp = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        let spawnCode = withCStringArray(argv) { argumentPointers in
            withCStringArray(envp) { environmentPointers in
                posix_spawn(
                    &childPID,
                    executable.path,
                    nil,
                    nil,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        guard spawnCode == 0 else {
            throw ChildProcessError.systemCall("posix_spawn", spawnCode)
        }

        let signalForwarder = SignalForwarder(childPID: childPID)
        defer { signalForwarder.stop() }

        var status: Int32 = 0
        while waitpid(childPID, &status, 0) == -1 {
            if errno == EINTR { continue }
            throw ChildProcessError.systemCall("waitpid", errno)
        }

        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return ChildResult(exitCode: (status >> 8) & 0xff)
        }
        return ChildResult(exitCode: 128 + terminationSignal)
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

private final class SignalForwarder {
    private let sources: [DispatchSourceSignal]
    private let previousINT: sig_t?
    private let previousTERM: sig_t?
    private let previousHUP: sig_t?
    private var stopped = false

    init(childPID: pid_t) {
        previousINT = signal(SIGINT, SIG_IGN)
        previousTERM = signal(SIGTERM, SIG_IGN)
        previousHUP = signal(SIGHUP, SIG_IGN)

        sources = [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global()
            )
            source.setEventHandler {
                _ = kill(childPID, signalNumber)
            }
            source.resume()
            return source
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        sources.forEach { $0.cancel() }
        _ = signal(SIGINT, previousINT)
        _ = signal(SIGTERM, previousTERM)
        _ = signal(SIGHUP, previousHUP)
    }
}
