import Foundation
import SimLeaseCore

public struct WaiterDisplayItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let projectAndSource: String
    public let elapsed: String
    public let command: String
    public let threadID: String?
    public let cwd: String
    public let estimate: String?
    public let headline: String
    public let subheadline: String
    public let waited: String
    public let targets: [String]
    public let reason: String?
    public let progress: Double?
    public let project: String?

    public init(
        id: String,
        name: String,
        projectAndSource: String,
        elapsed: String,
        command: String,
        threadID: String?,
        cwd: String,
        estimate: String? = nil,
        headline: String? = nil,
        subheadline: String? = nil,
        waited: String? = nil,
        targets: [String] = [],
        reason: String? = nil,
        progress: Double? = nil,
        project: String? = nil
    ) {
        self.reason = reason
        self.progress = progress
        self.project = project
        self.estimate = estimate
        self.headline = headline ?? name
        self.subheadline = subheadline ?? projectAndSource
        self.waited = waited ?? elapsed
        self.targets = targets
        self.id = id
        self.name = name
        self.projectAndSource = projectAndSource
        self.elapsed = elapsed
        self.command = command
        self.threadID = threadID
        self.cwd = cwd
    }
}

public struct DeviceDisplayItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let detail: String
    public let reservation: SimulatorUsage.Reservation
    public let user: String
    public let waiting: [String]
    public let unmanaged: [String]
    public let crashBlocked: Bool
    public let canShutDown: Bool
    public let runtime: String
    public let state: String
    public let runtimeStale: Bool
    public let lane: Int?
    public let ownerProject: String?
    public let ownerTitle: String?

    public init(id: String, name: String, detail: String, reservation: SimulatorUsage.Reservation, user: String, waiting: [String], unmanaged: [String], crashBlocked: Bool, canShutDown: Bool = false, runtime: String = "", state: String = "", runtimeStale: Bool = false, lane: Int? = nil, ownerProject: String? = nil, ownerTitle: String? = nil) {
        self.ownerTitle = ownerTitle
        self.lane = lane
        self.ownerProject = ownerProject
        self.runtimeStale = runtimeStale
        self.runtime = runtime
        self.state = state
        self.canShutDown = canShutDown
        self.id = id
        self.name = name
        self.detail = detail
        self.reservation = reservation
        self.user = user
        self.waiting = waiting
        self.unmanaged = unmanaged
        self.crashBlocked = crashBlocked
    }
}

public struct MenuAlert: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        case critical
        case warning
        case info

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let copyLabel: String?
    public let copyText: String?
    public let acknowledgeDeviceID: String?

    public init(id: String, severity: Severity, title: String, detail: String, copyLabel: String? = nil, copyText: String? = nil, acknowledgeDeviceID: String? = nil) {
        self.acknowledgeDeviceID = acknowledgeDeviceID
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.copyLabel = copyLabel
        self.copyText = copyText
    }
}

public struct RunningJobDisplay: Equatable, Sendable, Identifiable {
    public let lane: Int
    public let headline: String
    public let subheadline: String
    public let command: String
    public let elapsed: String
    public let elapsedSeconds: Double
    public let typicalSeconds: Double?
    public let exclusive: Bool
    public let project: String

    public var id: Int { lane }

    public init(lane: Int, headline: String, subheadline: String, command: String, elapsed: String, elapsedSeconds: Double, typicalSeconds: Double?, exclusive: Bool, project: String = "") {
        self.project = project
        self.lane = lane
        self.headline = headline
        self.subheadline = subheadline
        self.command = command
        self.elapsed = elapsed
        self.elapsedSeconds = elapsedSeconds
        self.typicalSeconds = typicalSeconds
        self.exclusive = exclusive
    }
}

public struct MenuDisplayState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case free
        case leased
        case metadataError
    }

    public let kind: Kind
    public let menuTitle: String
    public let symbolName: String
    public let ownerName: String?
    public let projectAndSource: String?
    public let command: String?
    public let elapsed: String?
    public let waiters: [WaiterDisplayItem]
    public let error: String?
    public let activity: SimulatorActivityReport?
    public let crashBlocks: [CrashLoopTrigger]
    public let devices: [DeviceDisplayItem]?
    public let typicalDuration: String?
    public let nativeIdle: String?
    public let alerts: [MenuAlert]
    public let ownerHeadline: String?
    public let ownerSubheadline: String?
    public let ownerElapsedSeconds: Double?
    public let ownerTypicalSeconds: Double?
    public let running: [RunningJobDisplay]
    public let laneSummary: String?
    public let headroom: HeadroomDisplay?
    public let laneBars: [LaneBarDisplay]

    public var waiterNames: [String] {
        waiters.map(\.name)
    }

    public init(status: LeaseStatus, now: Date) {
        let base = Self(leaseStatus: status, now: now)
        let activity = status.activity
        let title: String
        if status.state == .metadataError { title = base.menuTitle }
        else if status.crashBlocks?.isEmpty == false { title = "Simulator · Crash blocked" }
        else if activity?.activities.contains(where: { $0.kind == .unmanaged }) == true { title = "Simulator · Unmanaged" }
        else if activity?.isIncomplete == true { title = "Simulator · Audit incomplete" }
        else if activity?.activities.isEmpty == false { title = "Simulator · Unverified" }
        else { title = base.menuTitle }
        let typical = status.typicalDurations ?? [:]
        let leased = base.kind == .leased ? status.owner : nil
        let ownerTypical = leased.flatMap { typical[$0.project] }
        var ahead = ownerTypical.map { max($0 - now.timeIntervalSince(leased!.acquiredAt), 60) }
        var estimates = [String: String]()
        var estimateSeconds = [String: Double]()
        for waiter in status.waiters.sorted(by: { $0.waitingSince < $1.waitingSince }) {
            guard let wait = ahead else { break }
            estimateSeconds[waiter.id] = wait
            estimates[waiter.id] = "starts in ≈ \(Self.minutes(wait))"
            ahead = typical[waiter.project].map { wait + $0 }
        }
        let usage = Dictionary((status.devices ?? []).map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let recorded = Dictionary(status.waiters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let arrival = { (item: WaiterDisplayItem) in recorded[item.id]?.waitingSince ?? .distantFuture }
        let queued = status.waiters.map { waiter in
            WaiterDisplayItem(id: waiter.id, name: Self.name(title: waiter.threadTitle, threadID: waiter.threadID, source: waiter.source, project: waiter.project), projectAndSource: "\(waiter.project) · \(Self.sourceName(waiter.source))", elapsed: Self.elapsed(from: waiter.waitingSince, to: now), command: waiter.command.joined(separator: " "), threadID: waiter.threadID, cwd: waiter.cwd)
        }
        let waiters = queued.sorted { arrival($0) < arrival($1) }.map { item -> WaiterDisplayItem in
            let waiter = recorded[item.id]
            let labels = waiter.map { Self.labels(title: $0.threadTitle, threadID: $0.threadID, source: $0.source, project: $0.project) }
            let targets = (waiter?.deviceIDs ?? []).map { id in
                usage[id.uppercased()].map { "\($0.name) · \($0.runtime)" } ?? String(id.prefix(8))
            }
            let busy = Set((status.lanes ?? []).flatMap { $0.deviceIDs.map { $0.uppercased() } })
            let blockedBy = (waiter?.deviceIDs ?? []).first { busy.contains($0.uppercased()) }
            let reason: String? = if status.state == .metadataError {
                "lane metadata needs inspection"
            } else if waiter?.exclusive == true || (waiter?.deviceIDs ?? []).isEmpty {
                "needs all lanes"
            } else if let blockedBy {
                "waiting for \(usage[blockedBy.uppercased()]?.name ?? String(blockedBy.prefix(8)))"
            } else {
                "waiting for a lane"
            }
            let waited = waiter.map { now.timeIntervalSince($0.waitingSince) } ?? 0
            let remaining = estimateSeconds[item.id]
            return WaiterDisplayItem(
                id: item.id, name: item.name, projectAndSource: item.projectAndSource, elapsed: item.elapsed, command: item.command,
                threadID: item.threadID, cwd: item.cwd, estimate: estimates[item.id], headline: labels?.0, subheadline: labels?.1,
                waited: waiter.map { "waiting \(Self.minutes(now.timeIntervalSince($0.waitingSince)))" }, targets: targets,
                reason: reason, progress: remaining.map { waited / max(1, waited + $0) }, project: waiter?.project
            )
        }
        let idle = leased == nil ? nil : status.nativeIdleSince.map { now.timeIntervalSince($0) }.flatMap { $0 >= 600 ? $0 : nil }
        let ownerLabels = leased.map { Self.labels(title: $0.threadTitle, threadID: $0.threadID, source: $0.source, project: $0.project) }
        self.init(
            kind: base.kind, menuTitle: title,
            symbolName: title != base.menuTitle ? "exclamationmark.triangle.fill" : base.symbolName,
            ownerName: base.ownerName, projectAndSource: base.projectAndSource,
            command: base.command, elapsed: base.elapsed, waiters: waiters, error: base.error, activity: activity, crashBlocks: status.crashBlocks ?? [],
            devices: status.devices.map { Self.devices($0, status: status, ownerName: base.ownerName, waiters: waiters, now: now) },
            typicalDuration: ownerTypical.map { "usually ≈ \(Self.minutes($0))" },
            nativeIdle: idle.map { "No native device commands for \(Self.minutes($0)). Finish the session if it is done." },
            alerts: Self.laneAlerts(status) + Self.alerts(status: status, usage: usage, idle: idle),
            ownerHeadline: ownerLabels?.0, ownerSubheadline: ownerLabels?.1,
            ownerElapsedSeconds: leased.map { max(0, now.timeIntervalSince($0.acquiredAt)) }, ownerTypicalSeconds: ownerTypical,
            running: Self.running(status: status, typical: typical, now: now),
            laneSummary: Self.laneSummary(status),
            headroom: status.gate.map { HeadroomDisplay(memoryFreePercent: $0.memoryFreePercent, cpuIdlePercent: $0.cpuIdlePercent, load: $0.load, cpus: $0.cpus, open: $0.open, reason: $0.reason, laneLimit: status.laneLimit ?? 1) },
            laneBars: Self.laneBars(status: status, typical: typical, now: now)
        )
    }

    private static func laneBars(status: LeaseStatus, typical: [String: Double], now: Date) -> [LaneBarDisplay] {
        guard status.state != .metadataError || status.laneErrors?.isEmpty == false else { return [] }
        let limit = status.laneLimit ?? 1
        let lanes = observedLanes(status)
        let exclusive = lanes.first(where: \.exclusive)
        let count = limit > 1 ? LeasePaths.maximumLanes : 1
        return (0..<count).map { index in
            if let issue = status.laneErrors?.first(where: { $0.lane == index }) {
                return LaneBarDisplay(lane: index, kind: .blocked, title: issue.phase == .quarantined ? "quarantined · cleanup unresolved" : "blocked · unresolved metadata", subtitle: issue.message, detail: "", project: issue.owner?.project, fraction: 0, overrun: false, exclusive: false)
            }
            let job = exclusive ?? lanes.first { $0.lane == index }
            if let job {
                let elapsed = max(0, now.timeIntervalSince(job.owner.acquiredAt))
                let expected = typical[job.owner.project]
                let labels = Self.labels(title: job.owner.threadTitle, threadID: job.owner.threadID, source: job.owner.source, project: job.owner.project)
                let detail = expected.map { elapsed > $0 ? "\(Self.minutes(elapsed)) ⚠︎" : "\(Self.minutes(elapsed)) / \(Self.minutes($0))" } ?? Self.minutes(elapsed)
                return LaneBarDisplay(lane: index, kind: .running, title: labels.0, subtitle: labels.1, detail: detail, project: job.owner.project, fraction: expected.map { min(1, elapsed / max($0, 1)) } ?? 1, overrun: expected.map { elapsed > $0 } ?? false, exclusive: job.exclusive)
            }
            if index >= limit { return LaneBarDisplay(lane: index, kind: .off, title: "off · max lanes \(limit)", detail: "", project: nil, fraction: 0, overrun: false, exclusive: false) }
            if status.state == .metadataError { return LaneBarDisplay(lane: index, kind: .blocked, title: "availability unresolved", detail: "", project: nil, fraction: 0, overrun: false, exclusive: false) }
            if index > 0, status.gate?.open == false { return LaneBarDisplay(lane: index, kind: .closed, title: "closed · \(status.gate?.reason ?? "low headroom")", detail: "", project: nil, fraction: 0, overrun: false, exclusive: false) }
            return LaneBarDisplay(lane: index, kind: .free, title: "free", detail: "", project: nil, fraction: 0, overrun: false, exclusive: false)
        }
    }

    private static func running(status: LeaseStatus, typical: [String: Double], now: Date) -> [RunningJobDisplay] {
        let lanes = observedLanes(status)
        return lanes.map { lane in
            let labels = Self.labels(title: lane.owner.threadTitle, threadID: lane.owner.threadID, source: lane.owner.source, project: lane.owner.project)
            return RunningJobDisplay(
                lane: lane.lane, headline: labels.0, subheadline: labels.1, command: lane.owner.command.joined(separator: " "),
                elapsed: Self.elapsed(from: lane.owner.acquiredAt, to: now), elapsedSeconds: max(0, now.timeIntervalSince(lane.owner.acquiredAt)),
                typicalSeconds: typical[lane.owner.project], exclusive: lane.exclusive, project: lane.owner.project
            )
        }
    }

    private static func observedLanes(_ status: LeaseStatus) -> [LaneStatus] {
        status.lanes ?? (status.state == .leased ? status.owner.map { [LaneStatus(lane: 0, owner: $0, deviceIDs: [], exclusive: false)] } : nil) ?? []
    }

    private static func laneAlerts(_ status: LeaseStatus) -> [MenuAlert] {
        (status.laneErrors ?? []).map { issue in
            MenuAlert(id: "lane-\(issue.lane)", severity: .critical, title: "Lane \(issue.lane + 1) \(issue.phase == .quarantined ? "quarantined" : "blocked")", detail: issue.message)
        }
    }

    private static func laneSummary(_ status: LeaseStatus) -> String? {
        guard let limit = status.laneLimit, limit > 1 else { return nil }
        let used = (status.lanes ?? []).contains(where: \.exclusive) ? limit : (status.lanes ?? []).count
        if status.state == .metadataError {
            guard let issues = status.laneErrors, !issues.isEmpty else { return nil }
            return "\(used) running · \(issues.count) lanes need attention"
        }
        var parts = ["\(used) of \(limit) lanes in use"]
        if let gate = status.gate {
            parts.append(gate.open ? "headroom open" : "extra lane closed, \(gate.reason ?? "low headroom")")
            if gate.open, let free = gate.memoryFreePercent { parts.append("memory \(free)% free") }
        }
        return parts.joined(separator: " · ")
    }

    private static func labels(title: String?, threadID: String?, source: LeaseSource, project: String) -> (String, String) {
        if source == .manualXcode { return ("Manual Xcode", project) }
        if let title = displayTitle(title, project: project) { return (title, "\(project) · \(sourceName(source))") }
        if let threadID, !threadID.isEmpty { return (project, "\(sourceName(source)) · \(threadID.prefix(8))") }
        return (project, sourceName(source))
    }

    private static func alerts(status: LeaseStatus, usage: [String: SimulatorUsage], idle: Double?) -> [MenuAlert] {
        var alerts = [MenuAlert]()
        for block in status.crashBlocks ?? [] {
            let place = usage[block.deviceID.uppercased()].map { "\($0.name) · \($0.runtime)" } ?? "simulator \(block.deviceID.prefix(8))"
            alerts.append(MenuAlert(
                id: "crash-\(block.deviceID)", severity: .critical, title: "\(block.processName) keeps crashing",
                detail: "New jobs on \(place) are blocked until the crash is reviewed. Allow retries once the cause is fixed; new repeated crashes block it again.",
                copyLabel: "Copy unblock command", copyText: "simlease device acknowledge --device \(block.deviceID)",
                acknowledgeDeviceID: block.deviceID
            ))
        }
        let activities = status.activity?.activities ?? []
        let outside = activities.filter { $0.kind == .unmanaged }
        if !outside.isEmpty {
            alerts.append(MenuAlert(
                id: "unmanaged", severity: .warning, title: "Simulator work outside SimLease",
                detail: outside.prefix(3).map { "\($0.tool) PID \($0.process.pid)" }.joined(separator: ", ") + (outside.count > 3 ? " and \(outside.count - 3) more" : "") + " can collide with leased jobs."
            ))
        }
        let unverified = activities.filter { $0.kind != .unmanaged }
        if !unverified.isEmpty {
            alerts.append(MenuAlert(
                id: "unverified", severity: .info, title: "Ownership unverified",
                detail: unverified.prefix(3).map { "\($0.tool) PID \($0.process.pid)" }.joined(separator: ", ") + " matched a reservation, which does not prove who started it."
            ))
        }
        if let activity = status.activity, activity.isIncomplete {
            alerts.append(MenuAlert(
                id: "audit", severity: .info, title: "Process audit incomplete",
                detail: activity.error ?? "\(activity.uninspectedProcessCount) processes could not be inspected."
            ))
        }
        for runtime in status.staleRuntimes ?? [] {
            let affected = usage.values.filter { $0.runtimeStale == true }.count
            alerts.append(MenuAlert(
                id: "runtime-\(runtime.identifier)", severity: .warning, title: "iOS \(runtime.version) runtime is older than Xcode",
                detail: "Runtime \(runtime.build) predates the SDK \(runtime.sdkBuild)\(affected > 0 ? " used by \(affected) listed simulator\(affected == 1 ? "" : "s")" : ""). Apps built with this Xcode can crash calling missing system symbols, such as Date comparisons.",
                copyLabel: "Copy install command", copyText: "xcodebuild -downloadPlatform iOS"
            ))
        }
        if let idle {
            alerts.append(MenuAlert(
                id: "native-idle", severity: .warning, title: "Native session looks idle",
                detail: "No device commands for \(minutes(idle)). Finish the session if it is done; it holds the lane."
            ))
        }
        return alerts.sorted { $0.severity < $1.severity }
    }

    private static func minutes(_ seconds: Double) -> String {
        "\(max(1, Int((seconds / 60).rounded()))) min"
    }

    private static func devices(_ usage: [SimulatorUsage], status: LeaseStatus, ownerName: String?, waiters: [WaiterDisplayItem], now: Date) -> [DeviceDisplayItem] {
        let names = Dictionary(waiters.map { ($0.id, $0.headline) }, uniquingKeysWith: { first, _ in first })
        let blocked = Set((status.crashBlocks ?? []).map { $0.deviceID.uppercased() })
        return usage.map { device in
            let owner = [.owned, .borrowed].contains(device.reservation)
                ? ((status.lanes ?? []).first { $0.deviceIDs.contains { $0.uppercased() == device.id } }?.owner ?? status.owner)
                : nil
            let waiting = status.waiters.filter { $0.deviceIDs?.contains { $0.uppercased() == device.id } == true }.compactMap { names[$0.id] }
            let targeted = (status.activity?.activities ?? []).contains { $0.deviceIDs.isEmpty || $0.deviceIDs.contains { $0.uppercased() == device.id } }
            let user = switch device.reservation {
            case .owned: "\(ownerName ?? "Unknown owner") · shuts down after"
            case .borrowed: "\(ownerName ?? "Unknown owner") · stays running after"
            case .warm: "Kept warm by SimLease · idle \(max(0, Int(now.timeIntervalSince(device.warmSince ?? now) / 60))) min"
            case .unreserved: "No SimLease reservation"
            }
            return DeviceDisplayItem(
                id: device.id,
                name: device.name,
                detail: [device.runtime, device.state].filter { !$0.isEmpty }.joined(separator: " · "),
                reservation: device.reservation,
                user: user,
                waiting: waiting,
                unmanaged: (status.activity?.activities ?? []).filter { $0.kind == .unmanaged && $0.deviceIDs.contains { $0.uppercased() == device.id } }
                    .map { "\($0.tool) · PID \($0.process.pid)" },
                crashBlocked: blocked.contains(device.id),
                canShutDown: status.state != .metadataError && [.unreserved, .warm].contains(device.reservation) && device.state == "Booted" && waiting.isEmpty && !targeted,
                runtime: device.runtime, state: device.state, runtimeStale: device.runtimeStale == true, lane: (status.laneLimit ?? 1) > 1 ? device.lane : nil,
                ownerProject: owner?.project,
                ownerTitle: owner.flatMap { displayTitle($0.threadTitle, project: $0.project) }
            )
        }
    }

    private init(leaseStatus status: LeaseStatus, now: Date) {
        switch status.state {
        case .free:
            self = .free
        case .metadataError:
            self = .metadataError(status.error ?? "Unable to read lease metadata")
        case .leased:
            guard let owner = status.owner else {
                self = .metadataError("Lease owner metadata is missing")
                return
            }

            let elapsed = Self.elapsed(from: owner.acquiredAt, to: now)
            kind = .leased
            menuTitle = "Simulator · \(elapsed)"
            symbolName = "hourglass.circle.fill"
            ownerName = Self.name(
                title: owner.threadTitle,
                threadID: owner.threadID,
                source: owner.source,
                project: owner.project
            )
            projectAndSource = "\(owner.project) · \(Self.sourceName(owner.source))"
            command = owner.command.joined(separator: " ")
            self.elapsed = elapsed
            waiters = []
            error = nil
            activity = nil
            crashBlocks = []
            devices = nil
            typicalDuration = nil
            nativeIdle = nil
            alerts = []
            ownerHeadline = nil
            ownerSubheadline = nil
            ownerElapsedSeconds = nil
            ownerTypicalSeconds = nil
            running = []
            laneSummary = nil
            headroom = nil
            laneBars = []
        }
    }

    public static var free: MenuDisplayState {
        MenuDisplayState(
            kind: .free,
            menuTitle: "Simulator · Free",
            symbolName: "checkmark.circle.fill",
            ownerName: nil,
            projectAndSource: nil,
            command: nil,
            elapsed: nil,
            waiters: [],
            error: nil
        )
    }

    public static func metadataError(_ message: String) -> MenuDisplayState {
        MenuDisplayState(
            kind: .metadataError,
            menuTitle: "Simulator · Error",
            symbolName: "exclamationmark.triangle.fill",
            ownerName: nil,
            projectAndSource: nil,
            command: nil,
            elapsed: nil,
            waiters: [],
            error: message
        )
    }

    private init(
        kind: Kind,
        menuTitle: String,
        symbolName: String,
        ownerName: String?,
        projectAndSource: String?,
        command: String?,
        elapsed: String?,
        waiters: [WaiterDisplayItem],
        error: String?,
        activity: SimulatorActivityReport? = nil,
        crashBlocks: [CrashLoopTrigger] = [],
        devices: [DeviceDisplayItem]? = nil,
        typicalDuration: String? = nil,
        nativeIdle: String? = nil,
        alerts: [MenuAlert] = [],
        ownerHeadline: String? = nil,
        ownerSubheadline: String? = nil,
        ownerElapsedSeconds: Double? = nil,
        ownerTypicalSeconds: Double? = nil,
        running: [RunningJobDisplay] = [],
        laneSummary: String? = nil,
        headroom: HeadroomDisplay? = nil,
        laneBars: [LaneBarDisplay] = []
    ) {
        self.headroom = headroom
        self.laneBars = laneBars
        self.running = running
        self.laneSummary = laneSummary
        self.typicalDuration = typicalDuration
        self.nativeIdle = nativeIdle
        self.alerts = alerts
        self.ownerHeadline = ownerHeadline
        self.ownerSubheadline = ownerSubheadline
        self.ownerElapsedSeconds = ownerElapsedSeconds
        self.ownerTypicalSeconds = ownerTypicalSeconds
        self.devices = devices
        self.kind = kind
        self.menuTitle = menuTitle
        self.symbolName = symbolName
        self.ownerName = ownerName
        self.projectAndSource = projectAndSource
        self.command = command
        self.elapsed = elapsed
        self.waiters = waiters
        self.error = error
        self.activity = activity
        self.crashBlocks = crashBlocks
    }

    private static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds >= 3_600 {
            return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func name(
        title: String?,
        threadID: String?,
        source: LeaseSource,
        project: String
    ) -> String {
        if source == .manualXcode { return "Manual Xcode · \(project)" }
        if let title = displayTitle(title, project: project) { return title }
        if let threadID, !threadID.isEmpty { return String(threadID.prefix(8)) }
        return "\(sourceName(source)) · \(project)"
    }

    static func displayTitle(_ title: String?, project: String) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        guard title.hasPrefix("["), let close = title.firstIndex(of: "]") else { return title }
        let key = { (text: Substring) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let rest = title[title.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return key(title[title.index(after: title.startIndex)..<close]) == key(Substring(project)) && !rest.isEmpty ? rest : title
    }

    private static func sourceName(_ source: LeaseSource) -> String {
        switch source {
        case .codex: "Codex"
        case .claude: "Claude"
        case .terminal: "Terminal"
        case .manualXcode: "Xcode"
        case .nativeTool: "Native tool"
        }
    }
}
