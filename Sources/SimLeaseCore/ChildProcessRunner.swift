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

        var spawnAttributes: posix_spawnattr_t?
        let attributesCode = posix_spawnattr_init(&spawnAttributes)
        guard attributesCode == 0 else {
            throw ChildProcessError.systemCall(
                "posix_spawnattr_init",
                attributesCode
            )
        }
        defer { posix_spawnattr_destroy(&spawnAttributes) }

        var defaultSignals = sigset_t()
        guard sigemptyset(&defaultSignals) == 0 else {
            throw ChildProcessError.systemCall("sigemptyset", errno)
        }
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            guard sigaddset(&defaultSignals, signalNumber) == 0 else {
                throw ChildProcessError.systemCall("sigaddset", errno)
            }
        }
        let defaultsCode = posix_spawnattr_setsigdefault(
            &spawnAttributes,
            &defaultSignals
        )
        guard defaultsCode == 0 else {
            throw ChildProcessError.systemCall(
                "posix_spawnattr_setsigdefault",
                defaultsCode
            )
        }
        let flagsCode = posix_spawnattr_setflags(
            &spawnAttributes,
            Int16(POSIX_SPAWN_SETSIGDEF)
        )
        guard flagsCode == 0 else {
            throw ChildProcessError.systemCall(
                "posix_spawnattr_setflags",
                flagsCode
            )
        }

        let spawnCode = withCStringArray(argv) { argumentPointers in
            withCStringArray(envp) { environmentPointers in
                posix_spawn(
                    &childPID,
                    executable.path,
                    nil,
                    &spawnAttributes,
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
    private var stopped = false

    init(childPID: pid_t) {
        SignalDispositionCoordinator.shared.acquire()

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
        SignalDispositionCoordinator.shared.release()
    }
}

private final class SignalDispositionCoordinator: @unchecked Sendable {
    static let shared = SignalDispositionCoordinator()

    private let lock = NSLock()
    private var activeForwarders = 0
    private var previousINT: sig_t?
    private var previousTERM: sig_t?
    private var previousHUP: sig_t?

    func acquire() {
        lock.withLock {
            if activeForwarders == 0 {
                previousINT = signal(SIGINT, SIG_IGN)
                previousTERM = signal(SIGTERM, SIG_IGN)
                previousHUP = signal(SIGHUP, SIG_IGN)
            }
            activeForwarders += 1
        }
    }

    func release() {
        lock.withLock {
            precondition(activeForwarders > 0)
            activeForwarders -= 1
            guard activeForwarders == 0 else { return }
            _ = signal(SIGINT, previousINT)
            _ = signal(SIGTERM, previousTERM)
            _ = signal(SIGHUP, previousHUP)
            previousINT = nil
            previousTERM = nil
            previousHUP = nil
        }
    }
}
