import Foundation
import SimLeaseCore

public enum ProjectPalette {
    public static let slots = 7

    public static func slot(for project: String) -> Int {
        let key = project.lowercased().trimmingCharacters(in: .whitespaces)
        let hash = key.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1.value)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(slots))
    }
}

public struct HeadroomDisplay: Equatable, Sendable {
    public let memoryFreePercent: Int?
    public let cpuIdlePercent: Int?
    public let load: Double?
    public let cpus: Int?
    public let open: Bool
    public let reason: String?
    public let laneLimit: Int
}

public struct LaneBarDisplay: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case running
        case free
        case closed
        case blocked
        case off
    }

    public let lane: Int
    public let kind: Kind
    public let title: String
    public var subtitle: String = ""
    public let detail: String
    public let project: String?
    public let fraction: Double
    public let overrun: Bool
    public let exclusive: Bool

    public var id: Int { lane }
}

public struct DashboardSummary: Equatable, Sendable {
    public struct ProjectRow: Equatable, Sendable, Identifiable {
        public let project: String
        public let jobs: Int
        public let typicalSeconds: Double
        public let medianWaitSeconds: Double?
        public let crashes: Int
        public var id: String { project }
    }

    public struct TimelineItem: Equatable, Sendable, Identifiable {
        public let id: Int
        public let lane: Int
        public let project: String
        public let start: Date
        public let end: Date
        public let crashes: Int
        public let exclusive: Bool
    }

    public struct HeatCell: Equatable, Sendable, Identifiable {
        public let device: String
        public let hour: Date
        public let count: Int
        public var id: String { "\(device)-\(hour.timeIntervalSince1970)" }
    }

    public let jobsFinished: Int
    public let medianWaitSeconds: Double?
    public let extraLaneShare: Double?
    public let gateClosedShare: Double?
    public let crashBlocks: Int
    public let projects: [ProjectRow]
    public let timeline: [TimelineItem]
    public let closedIntervals: [ClosedRange<Date>]
    public let samples: [HeadroomRecord]
    public let heat: [HeatCell]

    public init(report: HistoryReport, now: Date) {
        let jobs = report.jobs.sorted { $0.endedAt < $1.endedAt }
        jobsFinished = jobs.count
        medianWaitSeconds = Self.median(jobs.compactMap(\.waitSeconds))
        let window = max(1, now.timeIntervalSince(report.since))
        let extraLaneSeconds = jobs.filter { ($0.lane ?? 0) > 0 }.reduce(0) { $0 + min($1.seconds, $1.endedAt.timeIntervalSince(report.since)) }
        extraLaneShare = report.laneLimit > 1 ? min(1, extraLaneSeconds / window) : nil
        let gated = report.samples.filter { $0.gateOpen != nil }
        gateClosedShare = gated.isEmpty ? nil : Double(gated.filter { $0.gateOpen == false }.count) / Double(gated.count)
        crashBlocks = report.blockedDeviceIDs.count
        timeline = jobs.enumerated().map { index, job in
            let crashes = report.crashes.filter { $0.occurredAt >= job.startedAt && $0.occurredAt <= job.endedAt && Self.matches($0.processName, job.project) }.count
            return TimelineItem(id: index, lane: job.lane ?? 0, project: job.project, start: max(job.startedAt, report.since), end: job.endedAt, crashes: crashes, exclusive: job.exclusive == true)
        }
        projects = Dictionary(grouping: jobs, by: \.project).map { project, entries in
            ProjectRow(
                project: project, jobs: entries.count,
                typicalSeconds: Self.median(entries.map(\.seconds)) ?? 0,
                medianWaitSeconds: Self.median(entries.compactMap(\.waitSeconds)),
                crashes: report.crashes.filter { Self.matches($0.processName, project) }.count
            )
        }.sorted { ($0.jobs, $1.project) > ($1.jobs, $0.project) }
        var intervals = [ClosedRange<Date>]()
        var start: Date?
        for (index, sample) in report.samples.enumerated() {
            if sample.gateOpen == false, start == nil { start = sample.at }
            let closesRun = sample.gateOpen != false || index == report.samples.count - 1
            if closesRun, let begun = start {
                let end = sample.gateOpen == false ? sample.at.addingTimeInterval(LaneHistoryStore.sampleInterval) : sample.at
                intervals.append(begun...max(begun, end))
                start = nil
            }
        }
        closedIntervals = intervals
        samples = report.samples
        let calendar = Calendar.current
        var buckets = [String: Int]()
        for crash in report.crashes {
            guard let hour = calendar.dateInterval(of: .hour, for: crash.occurredAt)?.start else { continue }
            let device = report.deviceNames[crash.deviceID] ?? String(crash.deviceID.prefix(8))
            buckets["\(device)|\(hour.timeIntervalSince1970)", default: 0] += 1
        }
        heat = buckets.map { key, count in
            let parts = key.split(separator: "|", maxSplits: 1)
            return HeatCell(device: String(parts[0]), hour: Date(timeIntervalSince1970: Double(parts[1]) ?? 0), count: count)
        }.sorted { ($0.device, $0.hour) < ($1.device, $1.hour) }
    }

    static func matches(_ processName: String, _ project: String) -> Bool {
        let process = processName.lowercased().filter(\.isLetter)
        let name = project.lowercased().filter(\.isLetter)
        guard !process.isEmpty, !name.isEmpty else { return false }
        return process.hasPrefix(name) || name.hasPrefix(process)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

public struct MenuBarIconState: Equatable, Sendable {
    public enum Lane: Equatable, Sendable {
        case busy(slot: Int)
        case free
        case closed
    }

    public enum Shape: Equatable, Sendable {
        case free
        case crash
        case error
        case ring(slot: Int, fraction: Double)
        case lanes([Lane])
    }

    public let shape: Shape
    public let text: String

    public init(state: MenuDisplayState) {
        if state.kind == .metadataError {
            shape = .error
            text = "Error"
        } else if !state.crashBlocks.isEmpty {
            shape = .crash
            text = "Crash blocked"
        } else if state.laneBars.count > 1 {
            let limit = state.headroom?.laneLimit ?? state.laneBars.count
            let lanes = state.laneBars.prefix(max(1, limit)).map { bar -> Lane in
                switch bar.kind {
                case .running: .busy(slot: ProjectPalette.slot(for: bar.project ?? ""))
                case .closed, .blocked: .closed
                case .free, .off: .free
                }
            }
            shape = .lanes(Array(lanes))
            let busy = state.laneBars.filter { $0.kind == .running }.count
            let waiting = state.waiters.count
            text = busy == 0 ? "Free" : waiting > 0 ? "\(busy) · \(waiting) waiting" : lanes.contains(.closed) ? "\(busy) · lane closed" : "\(busy) running"
        } else if let job = state.running.first {
            shape = .ring(slot: ProjectPalette.slot(for: job.project), fraction: job.typicalSeconds.map { min(1, job.elapsedSeconds / max($0, 1)) } ?? 1)
            text = "\(job.headline) · \(job.elapsed)"
        } else {
            shape = .free
            text = "Free"
        }
    }
}
