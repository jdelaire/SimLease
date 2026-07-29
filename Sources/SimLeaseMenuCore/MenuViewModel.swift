import Foundation
import Combine

@MainActor
public final class MenuViewModel: ObservableObject {
    @Published public private(set) var state: MenuDisplayState

    private let provider: any MenuStatusProviding
    private let now: () -> Date

    public init(
        provider: any MenuStatusProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.now = now
        state = .free
    }

    public func refresh() async {
        do {
            state = MenuDisplayState(status: try await provider.fetch(), now: now())
        } catch {
            state = .metadataError(error.localizedDescription)
        }
    }

    public var copyDetailsText: String {
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
