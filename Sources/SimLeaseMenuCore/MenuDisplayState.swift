import Foundation
import SimLeaseCore

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
    public let waiterNames: [String]
    public let error: String?

    public init(status: LeaseStatus, now: Date) {
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
            waiterNames = status.waiters.map {
                Self.name(
                    title: $0.threadTitle,
                    threadID: $0.threadID,
                    source: $0.source,
                    project: $0.project
                )
            }
            error = nil
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
            waiterNames: [],
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
            waiterNames: [],
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
        waiterNames: [String],
        error: String?
    ) {
        self.kind = kind
        self.menuTitle = menuTitle
        self.symbolName = symbolName
        self.ownerName = ownerName
        self.projectAndSource = projectAndSource
        self.command = command
        self.elapsed = elapsed
        self.waiterNames = waiterNames
        self.error = error
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
        }
    }
}
