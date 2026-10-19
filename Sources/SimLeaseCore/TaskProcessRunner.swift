import Darwin
import Foundation

public struct TaskProcessCleanupError: Error, Sendable {
    public let exitCode: Int32
    public let detail: String
}

public enum TaskProcessRunner {
    public static func run(
        executable: URL, arguments: [String], environment: [String: String],
        signals: TaskSignals, onStart: (ProcessReference) throws -> Void,
        onExit: (ProcessReference, Int32) throws -> Void = { _, _ in },
        onPoll: () -> Void = {}
    ) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        var code = posix_spawnattr_init(&attributes)
        guard code == 0 else { throw ChildProcessError.systemCall("spawnattr_init", code) }
        defer { posix_spawnattr_destroy(&attributes) }
        code = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
        guard code == 0 else { throw ChildProcessError.systemCall("spawnattr_setflags", code) }
        code = posix_spawnattr_setpgroup(&attributes, 0)
        guard code == 0 else { throw ChildProcessError.systemCall("spawnattr_setpgroup", code) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, number) }
        code = posix_spawnattr_setsigdefault(&attributes, &defaults)
        guard code == 0 else { throw ChildProcessError.systemCall("spawnattr_setsigdefault", code) }
        var pipeFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeFDs) == 0 else { throw ChildProcessError.systemCall("pipe", errno) }
        var gateOpen = true
        defer { if gateOpen { _ = close(pipeFDs[1]) } }
        _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeFDs[1], F_SETNOSIGPIPE, 1)
        var actions: posix_spawn_file_actions_t?
        code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else {
            _ = close(pipeFDs[0])
            throw ChildProcessError.systemCall("spawn_file_actions_init", code)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addclose(&actions, pipeFDs[1])
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[0], 3)
        if pipeFDs[0] != 3 { posix_spawn_file_actions_addclose(&actions, pipeFDs[0]) }
        let gate = "IFS= read -r ready <&3 || exit 125; [ \"$ready\" = run ] || exit 125; exec 3<&-; exec \"$@\""
        var child: pid_t = 0
        code = withStrings(["/bin/sh", "-c", gate, "simlease-worker", executable.path] + arguments) { argv in
            withStrings(environment.map { "\($0.key)=\($0.value)" }.sorted()) { envp in
                posix_spawn(&child, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }
        _ = close(pipeFDs[0])
        guard code == 0 else { throw ChildProcessError.systemCall("posix_spawn", code) }
        var reaped = false
        defer {
            if !reaped {
                _ = kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            }
        }
        guard let reference = ProcessReference.capture(pid: child) else {
            throw SimulatorTaskError.unverifiedProcess(child)
        }
        try onStart(reference)
        let written = "run\n".withCString { Darwin.write(pipeFDs[1], $0, 4) }
        _ = close(pipeFDs[1])
        gateOpen = false
        guard written == 4 else {
            throw ChildProcessError.systemCall("worker gate", errno)
        }
        var forwardedAt: Date?
        var observedExit: Int32 = 74
        while true {
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT)
            if result < 0 && errno != EINTR {
                throw ChildProcessError.systemCall("waitid", errno)
            }
            if result == 0 && info.si_pid == child {
                observedExit = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
                break
            }
            onPoll()
            if let number = signals.current {
                if forwardedAt == nil {
                    try signalGroup(reference, signal: number, retainedChild: true)
                    forwardedAt = Date()
                } else if Date().timeIntervalSince(forwardedAt!) > 3 {
                    try signalGroup(reference, signal: SIGKILL, retainedChild: true)
                }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        var cleanupError: Error?
        do { try onExit(reference, observedExit) } catch { cleanupError = error }
        do { try stopGroup(reference, retainedChild: true) } catch { cleanupError = cleanupError ?? error }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            guard errno == EINTR else { throw ChildProcessError.systemCall("waitpid", errno) }
        }
        reaped = true
        if let cleanupError {
            throw TaskProcessCleanupError(exitCode: observedExit, detail: String(describing: cleanupError))
        }
        let termination = status & 0x7f
        return termination == 0 ? (status >> 8) & 0xff : 128 + termination
    }

    public static func stopGroup(_ owner: ProcessReference) throws {
        try stopGroup(owner, retainedChild: false)
    }

    private static func stopGroup(_ owner: ProcessReference, retainedChild: Bool) throws {
        guard try !runningMembers(group: owner.pid).isEmpty else { return }
        try signalGroup(owner, signal: SIGTERM, retainedChild: retainedChild)
        let deadline = Date(timeIntervalSinceNow: 3)
        while try !runningMembers(group: owner.pid).isEmpty {
            if Date() >= deadline {
                try signalGroup(owner, signal: SIGKILL, retainedChild: retainedChild)
                let finalDeadline = Date(timeIntervalSinceNow: 2)
                while try !runningMembers(group: owner.pid).isEmpty {
                    guard Date() < finalDeadline else {
                        throw SimulatorTaskError.unverifiedProcess(owner.pid)
                    }
                    Thread.sleep(forTimeInterval: 0.03)
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    private static func signalGroup(_ owner: ProcessReference, signal: Int32, retainedChild: Bool = false) throws {
        var waitable = siginfo_t()
        var ownsRetainedChild = false
        if retainedChild {
            var result: Int32
            repeat {
                result = waitid(P_PID, id_t(owner.pid), &waitable, WEXITED | WNOHANG | WNOWAIT)
            } while result < 0 && errno == EINTR
            ownsRetainedChild = result == 0
        }
        let matchesLiveOwner = owner.state == .matching
            && ProcessReference.info(pid: owner.pid)?.pbi_pgid == UInt32(owner.pid)
        guard owner.pid > 1, ownsRetainedChild || matchesLiveOwner else {
            throw SimulatorTaskError.unverifiedProcess(owner.pid)
        }
        if kill(-owner.pid, signal) != 0 && errno != ESRCH {
            throw ChildProcessError.systemCall("killpg", errno)
        }
    }

    static func runningMembers(
        group: Int32, listPIDs: ((UnsafeMutableRawPointer?, Int32) -> Int32)? = nil
    ) throws -> [Int32] {
        guard group > 1 else { throw SimulatorTaskError.unverifiedProcess(group) }
        var buffer = [Int32](repeating: 0, count: 4096)
        let size = buffer.count * MemoryLayout<Int32>.size
        errno = 0
        let bytes = buffer.withUnsafeMutableBytes {
            if let listPIDs { return listPIDs($0.baseAddress, Int32(size)) }
            return proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32(size))
        }
        let inspectionError = errno
        if bytes == 0, inspectionError != 0, inspectionError != ESRCH {
            throw ChildProcessError.systemCall("proc_listpids", inspectionError)
        }
        guard bytes >= 0, bytes < size else {
            throw SimulatorTaskError.unverifiedProcess(group)
        }
        return try buffer.prefix(Int(bytes) / MemoryLayout<Int32>.size).filter { pid in
            guard pid > 0 else { return false }
            guard let info = ProcessReference.info(pid: pid) else {
                return ProcessReference.isRunning(pid: pid)
            }
            return info.pbi_status != 5
        }
    }

    private static func withStrings<Value>(
        _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Value
    ) -> Value {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { if let value = $0 { free(value) } } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
