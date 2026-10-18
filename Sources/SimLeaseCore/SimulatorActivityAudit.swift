import Foundation

public struct SimulatorActivityAudit: Sendable {
    private let reader: any SimulatorProcessReading

    public init() { reader = SystemSimulatorProcessReader() }
    init(reader: any SimulatorProcessReading) { self.reader = reader }

    public func scan(lease: LeaseStatus, task: SimulatorTaskRecord?) -> SimulatorActivityReport {
        var snapshots = [SimulatorProcessSnapshot]()
        var incomplete = 0
        do {
            let inventory = try reader.references()
            incomplete += inventory.uninspectedProcessCount
            for reference in inventory.references {
                do {
                    let snapshot = try reader.details(for: reference)
                    guard let current = reader.current(pid: reference.pid) else {
                        if !reader.hasExited(pid: reference.pid) { incomplete += 1 }
                        continue
                    }
                    guard current == reference else { incomplete += 1; continue }
                    snapshots.append(snapshot)
                } catch {
                    if !reader.hasExited(pid: reference.pid) { incomplete += 1 }
                }
            }
        } catch {
            return SimulatorActivityReport(error: "Process inventory could not be inspected")
        }
        let report = Self.evaluate(processes: snapshots, lease: lease, task: task)
        return SimulatorActivityReport(activities: report.activities, uninspectedProcessCount: incomplete, nativeClients: report.nativeClients ?? [])
    }

    static func evaluate(processes: [SimulatorProcessSnapshot], lease: LeaseStatus, task: SimulatorTaskRecord?) -> SimulatorActivityReport {
        let tree = Dictionary(processes.map { ($0.process.pid, $0) }, uniquingKeysWith: {
            $0.process.startMicroseconds >= $1.process.startMicroseconds ? $0 : $1
        })
        let owner: ProcessReference?
        if lease.state == .leased, let leased = lease.owner {
            if let task {
                owner = [.running, .cleaning].contains(task.phase) && leased.pid == task.owner.pid
                    && tree[task.owner.pid]?.process == task.owner ? task.owner : nil
            } else if let candidate = tree[leased.pid]?.process,
                      Double(candidate.startMicroseconds) / 1_000_000 <= leased.acquiredAt.timeIntervalSince1970 + 1 {
                owner = candidate
            } else { owner = nil }
        } else { owner = nil }
        let activities = tree.values.compactMap { snapshot -> SimulatorActivity? in
            guard let candidate = activity(in: snapshot) else { return nil }
            if let owner, descends(snapshot.process.pid, from: owner.pid, tree: tree) { return nil }
            if owner != nil, let task, task.phase == .running, task.externalWorkSettled != true,
               task.nativeClients?.contains(where: { tree[$0.pid]?.process == $0 && descends(snapshot.process.pid, from: $0.pid, tree: tree) }) == true,
               (try? NativeClientAdmission.validate(invocation: [candidate.tool] + Array(normalizedArguments(snapshot).dropFirst()), deviceIDs: task.deviceIDs)) != nil { return nil }
            let reserved = owner != nil && (lease.owner?.source == .manualXcode || lease.owner?.source == .nativeTool)
                && !candidate.ids.isEmpty && Set(candidate.ids).isSubset(of: Set(task?.deviceIDs ?? []))
            return SimulatorActivity(
                process: snapshot.process, tool: candidate.tool,
                kind: reserved ? .reservedNative : (candidate.knownSimulator ? .unmanaged : .targetUnknown),
                deviceIDs: candidate.ids
            )
        }.sorted { $0.process.pid < $1.process.pid }
        let clients = tree.values.compactMap { process -> SimulatorNativeClient? in
            guard let role = nativeRole(process) else { return nil }
            let bound = owner != nil && task?.externalSessionID != nil && task?.phase == .running
                && task?.externalWorkSettled != true && task?.nativeClients?.contains(process.process) == true
            return SimulatorNativeClient(process: process.process, role: role, bound: bound)
        }.sorted { $0.process.pid < $1.process.pid }
        return SimulatorActivityReport(activities: activities, nativeClients: clients)
    }

    private static func descends(_ pid: Int32, from ancestor: Int32, tree: [Int32: SimulatorProcessSnapshot]) -> Bool {
        var cursor = pid
        var seen = Set<Int32>()
        while cursor > 1, seen.insert(cursor).inserted {
            if cursor == ancestor { return true }
            guard let parent = tree[cursor]?.parentPID else { return false }
            cursor = parent
        }
        return false
    }

    private static func activity(in process: SimulatorProcessSnapshot) -> (tool: String, ids: [String], knownSimulator: Bool)? {
        var tool = URL(fileURLWithPath: process.executable).lastPathComponent
        var arguments = Array(process.arguments.dropFirst())
        if let script = arguments.firstIndex(where: {
            ["agent-device.mjs", "agent-device-launcher.mjs"].contains(URL(fileURLWithPath: $0).lastPathComponent)
        }), SystemSimulatorProcessReader.isNode(tool) {
            tool = "agent-device"
            arguments = Array(arguments.dropFirst(script + 1))
        }
        if tool == "xcrun", let selected = ProtectedCommand.selectedXcrunTool(in: arguments),
           let index = arguments.firstIndex(of: selected) {
            tool = selected
            arguments = Array(arguments.dropFirst(index + 1))
        }
        let invocation = [tool] + arguments
        let ids = SimulatorCommand.referencedDeviceIDs(in: invocation)
        switch tool {
        case "simctl":
            guard let action = arguments.first,
                  !["list", "help", "getenv", "get_app_container", "get_app_info", "listapps"].contains(action),
                  action != "runtime" || arguments.dropFirst().first == "delete"
            else { return nil }
            return (tool, ids, true)
        case "xcodebuild":
            guard !NativeClientAdmission.isPureXcodebuildQuery(arguments) else { return nil }
            let destinations = arguments.enumerated().compactMap { index, value -> String? in
                if value == "-destination", arguments.indices.contains(index + 1) { return arguments[index + 1] }
                return value.hasPrefix("-destination=") ? String(value.dropFirst(13)) : nil
            }
            if !destinations.isEmpty, destinations.allSatisfy({ $0.contains("platform=") && !$0.localizedCaseInsensitiveContains("simulator") }) { return nil }
            if destinations.isEmpty, let sdk = option("-sdk", arguments: arguments), !sdk.localizedCaseInsensitiveContains("simulator") { return nil }
            let simulatorSDK = arguments.contains { $0.localizedCaseInsensitiveContains("simulator") }
            guard ProtectedCommand.classify(invocation: invocation).requiresLease || simulatorSDK else { return nil }
            return (tool, ids, simulatorSDK || !ids.isEmpty)
        case "axe", "agent-device":
            if tool == "agent-device" {
                guard ProtectedCommand.classify(invocation: invocation).requiresLease,
                      !["devices", "apps", "logs"].contains(ProtectedCommand.agentDeviceCommand(in: arguments) ?? "")
                else { return nil }
            }
            let platform = option("--platform", arguments: arguments)?.lowercased()
            if let platform, platform != "ios" { return nil }
            if ["physical", "device"].contains(option("--target", arguments: arguments) ?? "") { return nil }
            if let udid = option("--udid", arguments: arguments), UUID(uuidString: udid) == nil,
               udid.filter({ $0 != "-" }).count >= 24, udid.filter({ $0 != "-" }).allSatisfy(\.isHexDigit) { return nil }
            return (tool, ids, !ids.isEmpty)
        default:
            return nil
        }
    }

    private static func normalizedArguments(_ process: SimulatorProcessSnapshot) -> [String] {
        let tool = URL(fileURLWithPath: process.executable).lastPathComponent
        let arguments = Array(process.arguments.dropFirst())
        if tool == "xcrun", let selected = ProtectedCommand.selectedXcrunTool(in: arguments), let index = arguments.firstIndex(of: selected) {
            return [selected] + Array(arguments.dropFirst(index + 1))
        }
        return process.arguments
    }

    private static func nativeRole(_ process: SimulatorProcessSnapshot) -> SimulatorNativeClient.Role? {
        guard SystemSimulatorProcessReader.isNode(URL(fileURLWithPath: process.executable).lastPathComponent),
              process.arguments.count >= 2, !process.arguments.dropFirst(2).contains(where: { ["--help", "-h", "--version"].contains($0) }) else { return nil }
        let entry = URL(fileURLWithPath: process.arguments[1]).standardizedFileURL.path
        if entry.hasSuffix("/node_modules/expo-device-hub/dist/server/cli.mjs") { return .deviceHub }
        if entry.hasSuffix("/node_modules/agent-device/dist/src/internal/daemon.js") || entry.hasSuffix("/node_modules/agent-device/dist/src/daemon.js") { return .agentDeviceDaemon }
        return nil
    }

    private static func option(_ name: String, arguments: [String]) -> String? {
        for (index, value) in arguments.enumerated() {
            if value == name, arguments.indices.contains(index + 1) { return arguments[index + 1] }
            if value.hasPrefix(name + "=") { return String(value.dropFirst(name.count + 1)) }
        }
        return nil
    }
}
