import Foundation
import Combine
import SimLeaseCore

@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public private(set) var summary: DashboardSummary?
    @Published public private(set) var error: String?
    @Published public var hours: Int = 6

    private let provider: any MenuStatusProviding
    private let now: () -> Date

    public init(provider: any MenuStatusProviding, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    public var since: Date { now().addingTimeInterval(-Double(hours) * 3600) }

    public func refresh() async {
        do {
            let report = try await provider.history(hours: hours)
            summary = DashboardSummary(report: report, now: now())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }
}
