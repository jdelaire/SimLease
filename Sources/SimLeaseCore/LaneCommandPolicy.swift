import Foundation

public enum LaneCommandScope: Equatable, Sendable {
    case passThrough
    case lane(slot: Int)
    case global
}

public enum LaneCommandPolicy {
    private static let deviceScopedSimctlVerbs: Set<String> = [
        "boot", "bootstatus", "shutdown", "install", "uninstall", "launch",
        "terminate", "spawn", "openurl", "privacy", "push", "status_bar",
        "ui", "keychain", "location", "io", "pbcopy", "pbpaste",
        "get_app_container", "listapps",
    ]

    public static func validate(
        invocation: [String],
        descriptor: LaneDescriptor?
    ) throws -> LaneCommandScope {
        let protection = ProtectedCommand.classify(invocation: invocation)
        guard protection.requiresLease else { return .passThrough }
        guard let descriptor else { return .global }

        switch protection.toolName {
        case "xcodebuild":
            return try validateXcodebuild(invocation, descriptor: descriptor)
        case "xcrun":
            return try validateSimctl(invocation, descriptor: descriptor)
        case "axe":
            return try validateAXe(invocation, descriptor: descriptor)
        default:
            return .global
        }
    }

    public static func explicitlyTargets(
        invocation: [String],
        udid: String
    ) -> Bool {
        guard let executable = invocation.first else { return false }
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "xcodebuild":
            return optionValues(
                "-destination",
                in: Array(invocation.dropFirst())
            ).contains { destinationUDID($0) == udid }
        case "xcrun":
            guard let toolIndex = selectedXcrunToolIndex(in: invocation),
                  invocation[toolIndex] == "simctl",
                  invocation.indices.contains(toolIndex + 2) else {
                return false
            }
            return invocation[toolIndex + 2] == udid
        case "axe":
            let arguments = Array(invocation.dropFirst())
            return arguments.indices.contains { index in
                arguments[index] == "--udid"
                    && arguments.indices.contains(index + 1)
                    && arguments[index + 1] == udid
            }
        default:
            return false
        }
    }

    private static func validateXcodebuild(
        _ invocation: [String],
        descriptor: LaneDescriptor
    ) throws -> LaneCommandScope {
        let arguments = Array(invocation.dropFirst())
        let destinations = optionValues("-destination", in: arguments)
        guard destinations.count <= 1 else { return .global }
        let actualUDID = destinations.first.flatMap(destinationUDID)
        guard actualUDID == descriptor.udid else {
            throw LaneServiceError.targetMismatch(
                expected: descriptor.udid,
                actual: actualUDID
            )
        }

        let derivedDataValues = optionValues("-derivedDataPath", in: arguments)
        guard derivedDataValues.count <= 1 else { return .global }
        let actualPath = derivedDataValues.first
        guard let actualPath,
              URL(fileURLWithPath: actualPath).standardizedFileURL.path
                == URL(fileURLWithPath: descriptor.derivedDataPath)
                    .standardizedFileURL.path else {
            throw LaneServiceError.derivedDataMismatch(
                expected: descriptor.derivedDataPath,
                actual: actualPath
            )
        }
        return .lane(slot: descriptor.slot)
    }

    private static func validateSimctl(
        _ invocation: [String],
        descriptor: LaneDescriptor
    ) throws -> LaneCommandScope {
        guard let toolIndex = selectedXcrunToolIndex(in: invocation),
              invocation[toolIndex] == "simctl",
              invocation.indices.contains(toolIndex + 1) else {
            return .global
        }
        let verb = invocation[toolIndex + 1]
        guard deviceScopedSimctlVerbs.contains(verb) else { return .global }
        let targetIndex = toolIndex + 2
        let actual = invocation.indices.contains(targetIndex)
            ? invocation[targetIndex]
            : nil
        guard actual == descriptor.udid else {
            throw LaneServiceError.targetMismatch(
                expected: descriptor.udid,
                actual: actual
            )
        }
        return .lane(slot: descriptor.slot)
    }

    private static func validateAXe(
        _ invocation: [String],
        descriptor: LaneDescriptor
    ) throws -> LaneCommandScope {
        let arguments = Array(invocation.dropFirst())
        if arguments.first == "list-simulators" { return .global }
        let indices = arguments.indices.filter { arguments[$0] == "--udid" }
        guard indices.count == 1,
              let index = indices.first,
              arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("--"),
              arguments[index + 1] == descriptor.udid else {
            throw LaneServiceError.unsupportedAXeTargeting
        }
        return .lane(slot: descriptor.slot)
    }

    private static func optionValues(
        _ option: String,
        in arguments: [String]
    ) -> [String] {
        var values: [String] = []
        var index = 0
        while arguments.indices.contains(index) {
            let argument = arguments[index]
            if argument == option {
                if arguments.indices.contains(index + 1) {
                    values.append(arguments[index + 1])
                }
                index += 2
            } else if argument.hasPrefix(option + "=") {
                values.append(String(argument.dropFirst(option.count + 1)))
                index += 1
            } else {
                index += 1
            }
        }
        return values
    }

    private static func destinationUDID(_ destination: String) -> String? {
        destination.split(separator: ",").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix("id=") })
            .map { String($0.dropFirst(3)) }
    }

    private static func selectedXcrunToolIndex(in invocation: [String]) -> Int? {
        let valueOptions = Set([
            "--sdk", "-sdk", "--toolchain", "-toolchain", "--log", "-log",
        ])
        var index = 1
        while invocation.indices.contains(index) {
            let argument = invocation[index]
            if valueOptions.contains(argument) {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                return index
            }
        }
        return nil
    }
}
