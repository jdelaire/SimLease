import Foundation

public enum ExecutableResolutionError: Error, Equatable {
    case notFound(String)
}

public enum ExecutableResolver {
    public static func resolve(
        name: String,
        path: String,
        excluding directory: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let excluded = directory.standardizedFileURL.resolvingSymlinksInPath()

        for component in path.split(separator: ":", omittingEmptySubsequences: false) {
            let path = component.isEmpty ? fileManager.currentDirectoryPath : String(component)
            let candidateDirectory = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard candidateDirectory != excluded else { continue }

            let candidate = candidateDirectory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path)
            else {
                continue
            }
            return candidate
        }

        throw ExecutableResolutionError.notFound(name)
    }
}
