import Foundation

public struct StaleRuntime: Codable, Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let build: String
    public let sdkBuild: String

    public init(identifier: String, version: String, build: String, sdkBuild: String) {
        self.identifier = identifier
        self.version = version
        self.build = build
        self.sdkBuild = sdkBuild
    }
}

public enum RuntimeCompatibility {
    public struct Runtime: Equatable, Sendable {
        let identifier: String
        let version: String
        let build: String

        public init(identifier: String, version: String, build: String) {
            self.identifier = identifier
            self.version = version
            self.build = build
        }
    }

    public static func stale(sdkVersion: String, sdkBuild: String, runtimes: [Runtime]) -> [StaleRuntime] {
        guard let sdk = order(sdkBuild) else { return [] }
        let matching = runtimes.filter { $0.version == sdkVersion && $0.identifier.contains("SimRuntime.iOS-") }
        let byIdentifier = Dictionary(grouping: matching, by: \.identifier)
        return byIdentifier.compactMap { identifier, candidates in
            guard let newest = candidates.compactMap({ runtime in order(runtime.build).map { (runtime, $0) } }).max(by: { $0.1.lexicographicallyPrecedes($1.1) }),
                  newest.1.lexicographicallyPrecedes(sdk) else { return nil }
            return StaleRuntime(identifier: identifier, version: newest.0.version, build: newest.0.build, sdkBuild: sdkBuild)
        }.sorted { $0.identifier < $1.identifier }
    }

    static func order(_ build: String) -> [Int]? {
        let pattern = /^(\d+)([A-Z])(\d+)([a-z]?)$/
        guard let match = build.wholeMatch(of: pattern), let major = Int(match.1), let number = Int(match.3) else { return nil }
        let letter = Int(match.2.unicodeScalars.first!.value)
        let suffix = match.4.unicodeScalars.first.map { Int($0.value) } ?? 0
        return [major, letter, number, suffix]
    }

    private struct Cached: Codable {
        let checkedAt: Date
        let stale: [StaleRuntime]
    }

    public static func cached(paths: LeasePaths, environment: [String: String], xcrunURL: URL, now: Date = Date()) -> [StaleRuntime] {
        let url = paths.root.appendingPathComponent("runtime-compatibility.json")
        if let cached = try? RecoveryFile.read(Cached.self, at: url), now.timeIntervalSince(cached.checkedAt) < 300, cached.checkedAt <= now {
            return cached.stale
        }
        let stale = current(environment: environment, xcrunURL: xcrunURL)
        try? RecoveryFile.write(Cached(checkedAt: now, stale: stale), at: url)
        return stale
    }

    public static func current(environment: [String: String], xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun")) -> [StaleRuntime] {
        guard let version = run(xcrunURL, ["--sdk", "iphonesimulator", "--show-sdk-version"], environment),
              let build = run(xcrunURL, ["--sdk", "iphonesimulator", "--show-sdk-build-version"], environment),
              let json = run(xcrunURL, ["simctl", "list", "runtimes", "--json"], environment),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let list = object["runtimes"] as? [[String: Any]]
        else { return [] }
        let runtimes = list.compactMap { entry -> Runtime? in
            guard let identifier = entry["identifier"] as? String, let version = entry["version"] as? String,
                  let build = entry["buildversion"] as? String, entry["isAvailable"] as? Bool != false else { return nil }
            return Runtime(identifier: identifier, version: version, build: build)
        }
        return stale(sdkVersion: version, sdkBuild: build, runtimes: runtimes)
    }

    private static func run(_ executable: URL, _ arguments: [String], _ environment: [String: String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
