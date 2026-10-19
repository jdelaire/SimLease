import Foundation

public struct LaneHistoryStore: Sendable {
    public static let capacity = 200
    public static let minimumSamples = 3

    private struct Entry: Codable {
        let project: String
        let seconds: Double
        let endedAt: Date
    }

    private struct NativeActivity: Codable {
        let sessionID: String
        let at: Date
    }

    private let historyURL: URL
    private let activityURL: URL

    public init(paths: LeasePaths) {
        historyURL = paths.root.appendingPathComponent("job-history.json")
        activityURL = paths.root.appendingPathComponent("native-activity.json")
    }

    public func record(project: String, startedAt: Date, endedAt: Date) throws {
        var entries = (try? RecoveryFile.read([Entry].self, at: historyURL)) ?? []
        entries.append(Entry(project: project, seconds: max(0, endedAt.timeIntervalSince(startedAt)), endedAt: endedAt))
        try RecoveryFile.write(Array(entries.suffix(Self.capacity)), at: historyURL)
    }

    public func typicalDurations(projects: Set<String>) -> [String: Double] {
        let entries = (try? RecoveryFile.read([Entry].self, at: historyURL)) ?? []
        var result = [String: Double]()
        for project in projects {
            let samples = entries.filter { $0.project == project }.suffix(20).map(\.seconds).sorted()
            guard samples.count >= Self.minimumSamples else { continue }
            result[project] = samples[samples.count / 2]
        }
        return result
    }

    public func recordNativeActivity(sessionID: String, at date: Date) throws {
        try RecoveryFile.write(NativeActivity(sessionID: sessionID, at: date), at: activityURL)
    }

    public func lastNativeActivity(sessionID: String) -> Date? {
        guard let activity = try? RecoveryFile.read(NativeActivity.self, at: activityURL), activity.sessionID == sessionID else { return nil }
        return activity.at
    }
}
