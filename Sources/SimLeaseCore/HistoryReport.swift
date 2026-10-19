import Foundation

public struct HistoryReport: Codable, Equatable, Sendable {
    public struct Crash: Codable, Equatable, Sendable {
        public let deviceID: String
        public let processName: String
        public let occurredAt: Date

        public init(deviceID: String, processName: String, occurredAt: Date) {
            self.deviceID = deviceID
            self.processName = processName
            self.occurredAt = occurredAt
        }
    }

    public let since: Date
    public let laneLimit: Int
    public let jobs: [JobRecord]
    public let samples: [HeadroomRecord]
    public let crashes: [Crash]
    public let blockedDeviceIDs: [String]
    public let deviceNames: [String: String]

    public init(since: Date, laneLimit: Int, jobs: [JobRecord], samples: [HeadroomRecord], crashes: [Crash], blockedDeviceIDs: [String], deviceNames: [String: String]) {
        self.since = since
        self.laneLimit = laneLimit
        self.jobs = jobs
        self.samples = samples
        self.crashes = crashes
        self.blockedDeviceIDs = blockedDeviceIDs
        self.deviceNames = deviceNames
    }
}
