import Foundation

public enum SimulatorCommand {
    public static func referencedDeviceIDs(in invocation: [String]) -> [String] {
        guard let executable = invocation.first else { return [] }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if isXcodebuild(executable: executable, arguments: Array(invocation.dropFirst())) {
            return deviceIDs(in: invocation)
        }
        if name == "simctl" || (name == "xcrun" && ProtectedCommand.selectedXcrunTool(in: Array(invocation.dropFirst())) == "simctl") {
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
