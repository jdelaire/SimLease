import Foundation

public struct ProtectionDecision: Equatable, Sendable {
    public let requiresLease: Bool
    public let toolName: String

    public init(requiresLease: Bool, toolName: String) {
        self.requiresLease = requiresLease
        self.toolName = toolName
    }
}

public enum ProtectedCommand {
    public static func classify(invocation: [String]) -> ProtectionDecision {
        guard let executable = invocation.first else {
            return ProtectionDecision(requiresLease: false, toolName: "")
        }

        let toolName = URL(fileURLWithPath: executable).lastPathComponent
        let arguments = Array(invocation.dropFirst())

        switch toolName {
        case "axe":
            return ProtectionDecision(requiresLease: true, toolName: toolName)
        case "xcrun":
            let selected = selectedXcrunTool(in: arguments)
            let lookup = selected.flatMap { arguments.firstIndex(of: $0) }.map {
                arguments.prefix($0).contains("--find") || arguments.prefix($0).contains("-f")
            } ?? false
            let simctlQuery = selected == "simctl" && arguments.firstIndex(of: "simctl").map {
                isSimctlQuery(Array(arguments.dropFirst($0 + 1)))
            } == true
            return ProtectionDecision(
                requiresLease: !lookup && ((selected == "simctl" && !simctlQuery) || selected == "xcodebuild"),
                toolName: toolName
            )
        case "agent-device":
            let informational = arguments.isEmpty
                || arguments == ["--help"] || arguments == ["--version"]
                || ["daemon", "capabilities", "help"].contains(agentDeviceCommand(in: arguments) ?? "")
            return ProtectionDecision(requiresLease: !informational, toolName: toolName)
        case "xcodebuild":
            let testActions = Set(["test", "test-without-building", "build-for-testing"])
            let hasTestAction = arguments.contains { testActions.contains($0) }
            let hasSimulatorDestination = arguments.enumerated().contains { index, argument in
                if argument == "-destination", arguments.indices.contains(index + 1) {
                    return arguments[index + 1].localizedCaseInsensitiveContains("simulator")
                }
                if argument.hasPrefix("-destination=") {
                    return argument.localizedCaseInsensitiveContains("simulator")
                }
                return false
            }
            return ProtectionDecision(
                requiresLease: hasTestAction || hasSimulatorDestination
                    || !SimulatorCommand.deviceIDs(in: invocation).isEmpty
                    || arguments.enumerated().contains { index, value in
                        (value == "-sdk" && arguments.indices.contains(index + 1) && arguments[index + 1].localizedCaseInsensitiveContains("simulator"))
                            || (value.hasPrefix("-sdk=") && value.localizedCaseInsensitiveContains("simulator"))
                    },
                toolName: toolName
            )
        default:
            return ProtectionDecision(requiresLease: false, toolName: toolName)
        }
    }

    private static func isSimctlQuery(_ arguments: [String]) -> Bool {
        var index = 0
        while arguments.indices.contains(index), ["--set", "--profiles"].contains(arguments[index]) {
            guard arguments.indices.contains(index + 1) else { return false }
            index += 2
        }
        guard arguments.indices.contains(index) else { return false }
        if arguments[index] == "runtime" {
            let rest = Array(arguments.dropFirst(index + 1))
            return rest.first == "list" || (rest.first == "match" && rest.dropFirst().first == "list")
        }
        return ["list", "help", "--help", "-h", "--version", "getenv", "get_app_container", "get_app_info", "listapps"].contains(arguments[index])
    }

    static func selectedXcrunTool(in arguments: [String]) -> String? {
        let valueOptions = Set([
            "--sdk", "-sdk",
            "--toolchain", "-toolchain",
        ])
        var index = 0

        while arguments.indices.contains(index) {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                return argument
            }
        }

        return nil
    }

    static func agentDeviceCommand(in arguments: [String]) -> String? {
        let values = Set(["--session", "--platform", "--device", "--udid", "--serial", "--host", "--port", "--config", "--state-dir"])
        let flags = Set(["--json", "--verbose", "--debug", "--no-color"])
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if values.contains(argument) {
                index += 2
            } else if flags.contains(argument) || (argument.hasPrefix("--") && argument.contains("=")) {
                index += 1
            } else {
                return argument.hasPrefix("-") ? nil : argument
            }
        }
        return nil
    }
}
