import Darwin
import Foundation

public final class NativeClientAdmission {
    private let gate: NativeAdmissionGate

    private init(gate: NativeAdmissionGate) { self.gate = gate }

    public static func capture(pids: [Int32]) throws -> [ProcessReference] {
        try Set(pids).sorted().map { pid in
            guard pid > 1, ProcessReference.info(pid: pid)?.pbi_uid == getuid(), let reference = ProcessReference.capture(pid: pid) else {
                throw SimulatorTaskError.unverifiedProcess(pid)
            }
            return reference
        }
    }

    public static func acquire(paths: LeasePaths, invocation: [String], pid: Int32) throws -> NativeClientAdmission? {
        let store = SimulatorTaskStore(paths: paths)
        guard let initial = try store.read(), initial.externalSessionID != nil,
              initial.nativeClients?.contains(where: { $0.isAncestor(of: pid) }) == true else { return nil }
        let gate = try NativeAdmissionGate(paths: paths, exclusive: false, timeout: 0)
        guard let record = try store.read(), record.token == initial.token,
              record.phase == .running, record.externalWorkSettled != true,
              record.owner.state == .matching,
              record.nativeClients?.contains(where: { $0.isAncestor(of: pid) }) == true,
              try !NativeSettlementStore(paths: paths).isAcknowledged(record)
        else { throw SimulatorTaskError.commandFailed("native session is ending or unavailable") }
        let coordinator = LeaseCoordinator(paths: paths, store: try MetadataStore(paths: paths))
        let lease = try coordinator.status()
        guard lease.state == .leased, lease.owner?.pid == record.owner.pid, lease.owner?.source == .nativeTool else {
            throw SimulatorTaskError.commandFailed("native session does not hold the lane")
        }
        try validate(invocation: invocation, deviceIDs: record.deviceIDs)
        return NativeClientAdmission(gate: gate)
    }

    public static func validate(invocation: [String], deviceIDs: [String]) throws {
        var arguments = Array(invocation.dropFirst())
        var tool = invocation.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        if tool == "xcrun", let selected = ProtectedCommand.selectedXcrunTool(in: arguments),
           let index = arguments.firstIndex(of: selected) {
            tool = selected
            arguments = Array(arguments.dropFirst(index + 1))
        }
        if tool == "xcodebuild" {
            try validateXcodebuild(arguments: arguments, deviceIDs: deviceIDs)
            return
        }
        guard tool == "simctl" else {
            throw SimulatorTaskError.commandFailed("bound native clients support only explicit simulator commands; use a separate managed scope")
        }
        if let action = arguments.first, ["list", "help", "--help", "--version"].contains(action) { return }
        let scoped = Set(["boot", "bootstatus", "shutdown", "io", "getenv", "get_app_container", "get_app_info", "listapps", "launch", "terminate", "spawn", "install", "uninstall", "ui", "status_bar", "keychain", "push", "privacy", "pbcopy", "pbpaste", "openurl", "addmedia"])
        guard arguments.count >= 2, scoped.contains(arguments[0]),
              let id = UUID(uuidString: arguments[1])?.uuidString, deviceIDs.contains(id) else {
            throw SimulatorTaskError.commandFailed("bound native command requires a declared UUID in its device target position")
        }
    }

    static func isPureXcodebuildQuery(_ arguments: [String]) -> Bool {
        let queries = Set(["-list", "-showBuildSettings", "-showdestinations", "-showsdks", "-version", "-help", "-find-executable", "-find-library", "-showTestPlans"])
        let values = Set(["-project", "-workspace", "-scheme", "-configuration", "-sdk", "-destination", "-destination-timeout", "-testPlan", "-find-executable", "-find-library"])
        var index = 0
        var query = false
        while index < arguments.count {
            let argument = arguments[index]
            if queries.contains(argument) { query = true }
            if values.contains(argument) {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else { return false }
                index += 2
            } else if queries.contains(argument) || ["-json", "-quiet", "-verbose"].contains(argument) {
                index += 1
            } else { return false }
        }
        return query
    }

    private static func validateXcodebuild(arguments: [String], deviceIDs: [String]) throws {
        if isPureXcodebuildQuery(arguments) { return }
        let hostModes = Set(["-runFirstLaunch", "-checkForNewerComponents", "-downloadPlatform", "-downloadAllPlatforms", "-importPlatform", "-downloadComponent", "-importComponent", "-deleteComponent", "-exportArchive", "-exportNotarizedApp", "-exportLocalizations", "-importLocalizations", "-license", "-create-xcframework", "-resolvePackageDependencies"])
        guard !arguments.contains(where: { hostModes.contains(String($0.split(separator: "=", maxSplits: 1).first ?? "")) }) else {
            throw SimulatorTaskError.commandFailed("host-wide xcodebuild operations require a separate managed scope")
        }
        var destinations = [String]()
        var index = 0
        var invalid = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-DVTSimulatorSetLocation") || argument.hasPrefix("-IDECustomSimulatorDeviceSet") { invalid = true }
            if argument == "-destination" || argument == "-sdk" {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else { invalid = true; break }
                let value = arguments[index + 1]
                if argument == "-destination" { destinations.append(value) }
                else if !value.lowercased().hasPrefix("iphonesimulator") && !value.lowercased().hasPrefix("appletvsimulator") && !value.lowercased().hasPrefix("watchsimulator") && !value.lowercased().hasPrefix("xrsimulator") { invalid = true }
                index += 2
                continue
            }
            if argument.hasPrefix("-destination=") { destinations.append(String(argument.dropFirst(13))) }
            if argument.hasPrefix("-sdk=") && !argument.lowercased().contains("simulator") { invalid = true }
            index += 1
        }
        let platforms = Set(["ios simulator", "tvos simulator", "watchos simulator", "visionos simulator"])
        for destination in destinations {
            var fields = [String: String]()
            for component in destination.split(separator: ",", omittingEmptySubsequences: false) {
                let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { invalid = true; continue }
                let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                if fields[key] != nil || !["id", "platform", "os", "arch"].contains(key) || value.isEmpty { invalid = true }
                fields[key] = value
            }
            if let platform = fields["platform"], !platforms.contains(platform.lowercased()) { invalid = true }
            guard let value = fields["id"], let id = UUID(uuidString: value)?.uuidString, deviceIDs.contains(id) else {
                invalid = true
                continue
            }
        }
        guard !invalid, !destinations.isEmpty else {
            throw SimulatorTaskError.commandFailed("bound runner build requires every destination to identify a declared simulator UUID")
        }
    }
}

final class NativeAdmissionGate {
    private let descriptor: Int32

    init(paths: LeasePaths, exclusive: Bool, timeout: TimeInterval) throws {
        let file = paths.root.appendingPathComponent("native-admission.lock")
        let candidate = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { throw ChildProcessError.systemCall("native admission open", errno) }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while flock(candidate, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                _ = close(candidate)
                throw ChildProcessError.systemCall("native admission lock", code)
            }
            guard Date() < deadline else {
                _ = close(candidate)
                throw SimulatorTaskError.commandTimedOut("native session admission or settlement")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        descriptor = candidate
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}
