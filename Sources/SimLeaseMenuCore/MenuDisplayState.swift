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

    public init(
        id: String,
        name: String,
        projectAndSource: String,
        elapsed: String,
        command: String,
        threadID: String?,
        cwd: String
    ) {
        self.id = id
        self.name = name
        self.projectAndSource = projectAndSource
        self.elapsed = elapsed
        self.command = command
        self.threadID = threadID
        self.cwd = cwd
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
        self.init(
            kind: base.kind, menuTitle: title,
            symbolName: title != base.menuTitle ? "exclamationmark.triangle.fill" : base.symbolName,
            ownerName: base.ownerName, projectAndSource: base.projectAndSource,
            command: base.command, elapsed: base.elapsed, waiters: base.waiters, error: base.error, activity: activity, crashBlocks: status.crashBlocks ?? []
        )
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
        crashBlocks: [CrashLoopTrigger] = []
    ) {
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
