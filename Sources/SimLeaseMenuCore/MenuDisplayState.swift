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
        targets: [String] = []
    ) {
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

    public init(id: String, name: String, detail: String, reservation: SimulatorUsage.Reservation, user: String, waiting: [String], unmanaged: [String], crashBlocked: Bool, canShutDown: Bool = false, runtime: String = "", state: String = "") {
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

    public init(id: String, severity: Severity, title: String, detail: String, copyLabel: String? = nil, copyText: String? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.copyLabel = copyLabel
        self.copyText = copyText
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
        for waiter in status.waiters.sorted(by: { $0.waitingSince < $1.waitingSince }) {
            guard let wait = ahead else { break }
            estimates[waiter.id] = "starts in ≈ \(Self.minutes(wait))"
            ahead = typical[waiter.project].map { wait + $0 }
        }
        let usage = Dictionary((status.devices ?? []).map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let recorded = Dictionary(status.waiters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let arrival = { (item: WaiterDisplayItem) in recorded[item.id]?.waitingSince ?? .distantFuture }
        let waiters = base.waiters.sorted { arrival($0) < arrival($1) }.map { item -> WaiterDisplayItem in
            let waiter = recorded[item.id]
            let labels = waiter.map { Self.labels(title: $0.threadTitle, threadID: $0.threadID, source: $0.source, project: $0.project) }
            let targets = (waiter?.deviceIDs ?? []).map { id in
                usage[id.uppercased()].map { "\($0.name) · \($0.runtime)" } ?? String(id.prefix(8))
            }
            return WaiterDisplayItem(
                id: item.id, name: item.name, projectAndSource: item.projectAndSource, elapsed: item.elapsed, command: item.command,
                threadID: item.threadID, cwd: item.cwd, estimate: estimates[item.id], headline: labels?.0, subheadline: labels?.1,
                waited: waiter.map { "waiting \(Self.minutes(now.timeIntervalSince($0.waitingSince)))" }, targets: targets
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
            alerts: status.state == .metadataError ? [] : Self.alerts(status: status, usage: usage, idle: idle),
            ownerHeadline: ownerLabels?.0, ownerSubheadline: ownerLabels?.1,
            ownerElapsedSeconds: leased.map { max(0, now.timeIntervalSince($0.acquiredAt)) }, ownerTypicalSeconds: ownerTypical
        )
    }

    private static func labels(title: String?, threadID: String?, source: LeaseSource, project: String) -> (String, String) {
        if source == .manualXcode { return ("Manual Xcode", project) }
        if let title, !title.isEmpty { return (title, "\(project) · \(sourceName(source))") }
        if let threadID, !threadID.isEmpty { return (project, "\(sourceName(source)) · \(threadID.prefix(8))") }
        return (project, sourceName(source))
    }

    private static func alerts(status: LeaseStatus, usage: [String: SimulatorUsage], idle: Double?) -> [MenuAlert] {
        var alerts = [MenuAlert]()
        for block in status.crashBlocks ?? [] {
            let place = usage[block.deviceID.uppercased()].map { "\($0.name) · \($0.runtime)" } ?? "simulator \(block.deviceID.prefix(8))"
            alerts.append(MenuAlert(
                id: "crash-\(block.deviceID)", severity: .critical, title: "\(block.processName) keeps crashing",
                detail: "New jobs on \(place) are blocked until the crash is reviewed.",
                copyLabel: "Copy unblock command", copyText: "simlease device repair --device \(block.deviceID) --acknowledge-crashes"
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
                canShutDown: [.unreserved, .warm].contains(device.reservation) && device.state == "Booted" && waiting.isEmpty && !targeted,
                runtime: device.runtime, state: device.state
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
            waiters = status.waiters.map { waiter in
                WaiterDisplayItem(
                    id: waiter.id,
                    name: Self.name(
                        title: waiter.threadTitle,
                        threadID: waiter.threadID,
                        source: waiter.source,
                        project: waiter.project
                    ),
                    projectAndSource:
                        "\(waiter.project) · \(Self.sourceName(waiter.source))",
                    elapsed: Self.elapsed(from: waiter.waitingSince, to: now),
                    command: waiter.command.joined(separator: " "),
                    threadID: waiter.threadID,
                    cwd: waiter.cwd
                )
            }
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
        ownerTypicalSeconds: Double? = nil
    ) {
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
        if let title, !title.isEmpty { return title }
        if let threadID, !threadID.isEmpty { return String(threadID.prefix(8)) }
        return "\(sourceName(source)) · \(project)"
    }

    private static func sourceName(_ source: LeaseSource) -> String {
        switch source {
        case .codex: "Codex"
        case .terminal: "Terminal"
        case .manualXcode: "Xcode"
        case .nativeTool: "Native tool"
        }
    }
}
