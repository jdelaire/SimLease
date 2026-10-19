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

    public init(
        id: String,
        name: String,
        projectAndSource: String,
        elapsed: String,
        command: String,
        threadID: String?,
        cwd: String,
        estimate: String? = nil
    ) {
        self.estimate = estimate
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

    public init(id: String, name: String, detail: String, reservation: SimulatorUsage.Reservation, user: String, waiting: [String], unmanaged: [String], crashBlocked: Bool, canShutDown: Bool = false) {
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
        let waiters = base.waiters.map {
            WaiterDisplayItem(id: $0.id, name: $0.name, projectAndSource: $0.projectAndSource, elapsed: $0.elapsed, command: $0.command, threadID: $0.threadID, cwd: $0.cwd, estimate: estimates[$0.id])
        }
        let idle = leased == nil ? nil : status.nativeIdleSince.map { now.timeIntervalSince($0) }.flatMap { $0 >= 600 ? $0 : nil }
        self.init(
            kind: base.kind, menuTitle: title,
            symbolName: title != base.menuTitle ? "exclamationmark.triangle.fill" : base.symbolName,
            ownerName: base.ownerName, projectAndSource: base.projectAndSource,
            command: base.command, elapsed: base.elapsed, waiters: waiters, error: base.error, activity: activity, crashBlocks: status.crashBlocks ?? [],
            devices: status.devices.map { Self.devices($0, status: status, ownerName: base.ownerName, waiters: waiters, now: now) },
            typicalDuration: ownerTypical.map { "usually ≈ \(Self.minutes($0))" },
            nativeIdle: idle.map { "No native device commands for \(Self.minutes($0)). Finish the session if it is done." }
        )
    }

    private static func minutes(_ seconds: Double) -> String {
        "\(max(1, Int((seconds / 60).rounded()))) min"
    }

    private static func devices(_ usage: [SimulatorUsage], status: LeaseStatus, ownerName: String?, waiters: [WaiterDisplayItem], now: Date) -> [DeviceDisplayItem] {
        let names = Dictionary(waiters.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
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
                canShutDown: [.unreserved, .warm].contains(device.reservation) && device.state == "Booted" && waiting.isEmpty && !targeted
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
        nativeIdle: String? = nil
    ) {
        self.typicalDuration = typicalDuration
        self.nativeIdle = nativeIdle
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
