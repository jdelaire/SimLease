import Foundation

enum ManagedToolEnvironment {
    static func make(
        executable: URL, arguments: [String], environment: [String: String], shimDirectory: URL? = nil
    ) -> [String: String] {
        let name = executable.lastPathComponent
        let isAgentDevice = ["agent-device", "agent-device.mjs"].contains(name)
            || (name == "node" && arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent == "agent-device.mjs" } == true)
        guard isAgentDevice, let path = environment["PATH"] else { return environment }
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/lib/simlease/shims").resolvingSymlinksInPath()
        let excluded = shimDirectory?.resolvingSymlinksInPath()
        var result = environment
        result["PATH"] = path.split(separator: ":", omittingEmptySubsequences: false).filter { component in
            let directory = URL(fileURLWithPath: component.isEmpty ? FileManager.default.currentDirectoryPath : String(component))
                .standardizedFileURL.resolvingSymlinksInPath()
            if directory == installed || directory == excluded { return false }
            let simlease = directory.appendingPathComponent("simlease")
            let xcrun = directory.appendingPathComponent("xcrun")
            return !FileManager.default.isExecutableFile(atPath: simlease.path)
                || simlease.resolvingSymlinksInPath() != xcrun.resolvingSymlinksInPath()
        }.joined(separator: ":")
        return result
    }
}
