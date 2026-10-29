import Foundation

public enum SimulatorCommand {
    static let scopedSimctlActions: Set<String> = ["boot", "bootstatus", "shutdown", "io", "getenv", "get_app_container", "get_app_info", "listapps", "launch", "terminate", "spawn", "install", "uninstall", "ui", "status_bar", "keychain", "push", "privacy", "pbcopy", "pbpaste", "openurl", "addmedia"]

    static func simctlDeviceTarget(in arguments: [String]) -> String? {
        guard let action = arguments.first, scopedSimctlActions.contains(action) else { return nil }
        let flags: Set<String>
        let values: Set<String>
        switch action {
        case "launch":
            flags = ["-w", "--wait-for-debugger", "--console", "--console-pty", "--terminate-running-process", "--checked-allocations"]
            values = ["-a", "--arch", "--stdout", "--stderr"]
        case "spawn":
            flags = ["-w", "--wait-for-debugger", "-s", "--standalone", "--checked-allocations"]
            values = ["-a", "--arch"]
        case "pbcopy", "pbpaste":
            flags = ["-v"]
            values = []
        default:
            flags = []
            values = []
        }
        var index = 1
        while arguments.indices.contains(index), arguments[index].hasPrefix("-") {
            let argument = arguments[index]
            if flags.contains(argument) {
                index += 1
            } else if values.contains(argument) {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty else { return nil }
                index += 2
            } else if argument.hasPrefix("--"), let separator = argument.firstIndex(of: "="),
                      values.contains(String(argument[..<separator])), argument.index(after: separator) < argument.endIndex {
                index += 1
            } else { return nil }
        }
        guard arguments.indices.contains(index) else { return nil }
        return UUID(uuidString: arguments[index])?.uuidString
    }

    public static func workspaceKey(in invocation: [String], cwd: String) -> String {
        let arguments = Array(invocation.dropFirst())
        func value(_ name: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument == name, arguments.indices.contains(index + 1) { return arguments[index + 1] }
                if argument.hasPrefix(name + "=") { return String(argument.dropFirst(name.count + 1)) }
            }
            return nil
        }
        let base = URL(fileURLWithPath: cwd, isDirectory: true)
        for name in ["-derivedDataPath", "-workspace", "-project"] {
            if let path = value(name) { return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path }
        }
        return base.standardizedFileURL.path
    }

    public static func bootTarget(in invocation: [String]) -> String? {
        guard let arguments = simctlArguments(invocation), arguments.count == 2, arguments[0] == "boot" else { return nil }
        return UUID(uuidString: arguments[1])?.uuidString
    }

    public static func shutdownRequiredTargets(in invocation: [String]) -> [String] {
        guard let arguments = simctlArguments(invocation), let action = arguments.first,
              ["erase", "delete", "clone", "boot"].contains(action) else { return [] }
        return arguments.dropFirst().compactMap { UUID(uuidString: $0)?.uuidString }
    }

    private static func simctlArguments(_ invocation: [String]) -> [String]? {
        guard let executable = invocation.first else { return nil }
        let arguments = Array(invocation.dropFirst())
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "simctl": return arguments
        case "xcrun":
            guard ProtectedCommand.selectedXcrunTool(in: arguments) == "simctl", let index = arguments.firstIndex(of: "simctl") else { return nil }
            return Array(arguments.dropFirst(index + 1))
        default: return nil
        }
    }

    public static func referencedDeviceIDs(in invocation: [String]) -> [String] {
        guard let executable = invocation.first else { return [] }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if isXcodebuild(executable: executable, arguments: Array(invocation.dropFirst())) {
            return deviceIDs(in: invocation)
        }
        if name == "simctl" || (name == "xcrun" && ProtectedCommand.selectedXcrunTool(in: Array(invocation.dropFirst())) == "simctl") {
            if let arguments = simctlArguments(invocation), let action = arguments.first, scopedSimctlActions.contains(action) {
                return simctlDeviceTarget(in: arguments).map { [$0] } ?? []
            }
            return Array(Set(invocation.dropFirst().compactMap { UUID(uuidString: $0)?.uuidString })).sorted()
        }
        guard name == "agent-device" else { return [] }
        var ids = Set<String>()
        for (index, argument) in invocation.enumerated() {
            if ["--udid", "--device"].contains(argument), invocation.indices.contains(index + 1),
               let id = UUID(uuidString: invocation[index + 1]) {
                ids.insert(id.uuidString)
            }
            for option in ["--udid=", "--device="] where argument.hasPrefix(option) {
                if let id = UUID(uuidString: String(argument.dropFirst(option.count))) {
                    ids.insert(id.uuidString)
                }
            }
        }
        return ids.sorted()
    }

    public static func deviceIDs(in invocation: [String]) -> [String] {
        guard let executable = invocation.first,
              isXcodebuild(executable: executable, arguments: Array(invocation.dropFirst()))
        else { return [] }
        var ids = Set<String>()
        for (index, argument) in invocation.enumerated() {
            let destination: String?
            if argument == "-destination", invocation.indices.contains(index + 1) {
                destination = invocation[index + 1]
            } else if argument.hasPrefix("-destination=") {
                destination = String(argument.dropFirst("-destination=".count))
            } else {
                destination = nil
            }
            guard let destination else { continue }
            if let platform = destination.split(separator: ",").first(where: { $0.hasPrefix("platform=") }),
               !platform.localizedCaseInsensitiveContains("simulator") { continue }
            for component in destination.split(separator: ",") where component.hasPrefix("id=") {
                if let id = UUID(uuidString: String(component.dropFirst(3))) {
                    ids.insert(id.uuidString)
                }
            }
        }
        return ids.sorted()
    }

    public static func argumentsForManagedTask(
        executable: String, arguments: [String], hasDevices: Bool
    ) -> [String] {
        guard isXcodebuild(executable: executable, arguments: arguments),
              arguments.contains(where: { ["test", "test-without-building", "build-for-testing"].contains($0) })
        else { return arguments }
        let options = ["-parallel-testing-enabled", "-maximum-concurrent-test-simulator-destinations"]
        var result = [String]()
        var index = 0
        while index < arguments.count {
            if options.contains(arguments[index]) {
                index += 2
            } else {
                result.append(arguments[index])
                index += 1
            }
        }
        return result + ["-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1"]
    }

    public static func isXcodebuild(executable: String, arguments: [String]) -> Bool {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if name == "xcodebuild" { return true }
        guard name == "xcrun", ProtectedCommand.selectedXcrunTool(in: arguments) == "xcodebuild",
              let index = arguments.firstIndex(of: "xcodebuild") else { return false }
        return !arguments.prefix(index).contains("--find") && !arguments.prefix(index).contains("-f")
    }
}
