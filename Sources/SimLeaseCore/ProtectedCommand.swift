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
            return ProtectionDecision(
                requiresLease: selectedXcrunTool(in: arguments) == "simctl",
                toolName: toolName
            )
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
                requiresLease: hasTestAction || hasSimulatorDestination,
                toolName: toolName
            )
        default:
            return ProtectionDecision(requiresLease: false, toolName: toolName)
        }
    }

    private static func selectedXcrunTool(in arguments: [String]) -> String? {
        let valueOptions = Set([
            "--sdk", "-sdk",
            "--toolchain", "-toolchain",
            "--log", "-log",
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
}
