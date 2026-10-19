import Foundation

public struct JobRecord: Codable, Equatable, Sendable {
    public let project: String
    public let seconds: Double
    public let endedAt: Date
    public let lane: Int?
    public let waitSeconds: Double?
    public let exclusive: Bool?

    public init(project: String, seconds: Double, endedAt: Date, lane: Int? = nil, waitSeconds: Double? = nil, exclusive: Bool? = nil) {
        self.project = project
        self.seconds = seconds
        self.endedAt = endedAt
        self.lane = lane
        self.waitSeconds = waitSeconds
        self.exclusive = exclusive
    }

    public var startedAt: Date { endedAt.addingTimeInterval(-seconds) }
}

public struct HeadroomRecord: Codable, Equatable, Sendable {
    public let at: Date
    public let memoryFreePercent: Int?
    public let cpuIdlePercent: Int?
    public let load: Double?
    public let lanesBusy: Int
    public let laneLimit: Int
    public let gateOpen: Bool?

    public init(at: Date, memoryFreePercent: Int?, cpuIdlePercent: Int?, load: Double?, lanesBusy: Int, laneLimit: Int, gateOpen: Bool?) {
        self.at = at
        self.memoryFreePercent = memoryFreePercent
        self.cpuIdlePercent = cpuIdlePercent
        self.load = load
        self.lanesBusy = lanesBusy
        self.laneLimit = laneLimit
        self.gateOpen = gateOpen
    }
}

public struct LaneHistoryStore: Sendable {
    public static let capacity = 2000
    public static let sampleCapacity = 1440
    public static let sampleInterval: TimeInterval = 60
    public static let minimumSamples = 3

    private typealias Entry = JobRecord

    private struct NativeActivity: Codable {
        let sessionID: String
        let at: Date
    }

    private let historyURL: URL
    private let activityURL: URL
    private let paths: LeasePaths

    public init(paths: LeasePaths) {
        self.paths = paths
        historyURL = paths.root.appendingPathComponent("job-history.json")
        activityURL = paths.root.appendingPathComponent("native-activity.json")
        samplesURL = paths.root.appendingPathComponent("headroom-history.json")
    }

    private let samplesURL: URL

    public func record(project: String, startedAt: Date, endedAt: Date, lane: Int? = nil, waitSeconds: Double? = nil, exclusive: Bool? = nil) throws {
        try SharedStateLock.withLock(paths) {
            var entries = (try? RecoveryFile.read([Entry].self, at: historyURL)) ?? []
            entries.append(Entry(project: project, seconds: max(0, endedAt.timeIntervalSince(startedAt)), endedAt: endedAt, lane: lane, waitSeconds: waitSeconds.map { max(0, $0) }, exclusive: exclusive))
            try RecoveryFile.write(Array(entries.suffix(Self.capacity)), at: historyURL)
        }
    }

    public func jobs(since: Date) -> [JobRecord] {
        ((try? RecoveryFile.read([Entry].self, at: historyURL)) ?? []).filter { $0.endedAt >= since }
    }

    public func recordSample(_ sample: HeadroomRecord) throws {
        try SharedStateLock.withLock(paths) {
            var samples = (try? RecoveryFile.read([HeadroomRecord].self, at: samplesURL)) ?? []
            if let last = samples.last, sample.at.timeIntervalSince(last.at) < Self.sampleInterval, sample.at >= last.at { return }
            samples.append(sample)
            try RecoveryFile.write(Array(samples.suffix(Self.sampleCapacity)), at: samplesURL)
        }
    }

    public func samples(since: Date) -> [HeadroomRecord] {
        ((try? RecoveryFile.read([HeadroomRecord].self, at: samplesURL)) ?? []).filter { $0.at >= since }
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
