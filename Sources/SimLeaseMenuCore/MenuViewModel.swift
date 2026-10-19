import Foundation
import Combine

@MainActor
public final class MenuViewModel: ObservableObject {
    @Published public private(set) var state: MenuDisplayState

    private let provider: any MenuStatusProviding
    private let now: () -> Date
    private var isRefreshing = false
    private var isMonitoring = false

    public init(
        provider: any MenuStatusProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.now = now
        state = .free
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let next = MenuDisplayState(status: try await provider.fetch(), now: now())
            if next != state { state = next }
        } catch {
            state = .metadataError(error.localizedDescription)
        }
    }

    public var copyDetailsText: String {
        var lines = [leaseDetailsText]
        for block in state.crashBlocks {
            lines.append("Crash blocked: \(block.processName) on \(block.deviceID)")
            lines.append("Inspect crash cause, then simlease device repair --device \(block.deviceID) --acknowledge-crashes")
        }
        if let activity = state.activity {
            for item in activity.activities {
                lines.append("\(item.kind.rawValue): \(item.tool) PID \(item.process.pid)")
            }
            if activity.isIncomplete { lines.append("Activity audit incomplete") }
        }
        return lines.joined(separator: "\n")
    }

    public func monitor() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        defer { isMonitoring = false }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    private var leaseDetailsText: String {
        switch state.kind {
        case .free:
            return "Simulator available"
        case .metadataError:
            return "Simulator metadata error\n\(state.error ?? "Unknown error")"
        case .leased:
            var lines = [
                "Owner: \(state.ownerName ?? "Unknown")",
                "Project: \(state.projectAndSource ?? "Unknown")",
                "Command: \(state.command ?? "Unknown")",
                "Elapsed: \(state.elapsed ?? "Unknown")",
                "Waiting: \(state.waiters.count)",
            ]
            for waiter in state.waiters {
                lines.append("- \(waiter.name)")
                lines.append(
                    "  \(waiter.projectAndSource) · \(waiter.elapsed)"
                )
                lines.append("  \(waiter.command)")
                if let threadID = waiter.threadID {
                    lines.append("  Thread: \(threadID)")
                }
                lines.append("  Path: \(waiter.cwd)")
            }
            return lines.joined(separator: "\n")
        }
    }
}
