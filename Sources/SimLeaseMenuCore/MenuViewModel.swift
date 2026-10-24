import Foundation
import Combine

@MainActor
public final class MenuViewModel: ObservableObject {
    @Published public private(set) var state: MenuDisplayState
    @Published public private(set) var shuttingDown: Set<String> = []
    @Published public private(set) var shutdownMessage: String?

    private let provider: any MenuStatusProviding
    private let now: () -> Date
    private var isRefreshing = false
    private var isMonitoring = false
    private var includesDevices = false
    private var refreshPending = false
    private var isReaping = false
    private var lastReap = Date.distantPast

    public init(
        provider: any MenuStatusProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.now = now
        state = .free
    }

    public func refresh() async {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshPending = false
            do {
                let next = MenuDisplayState(status: try await provider.fetch(includeDevices: includesDevices), now: now())
                if next != state { state = next }
            } catch {
                state = .metadataError(error.localizedDescription)
            }
        } while refreshPending
    }

    public func shutdown(_ ids: [String]) async {
        let pending = Set(ids).subtracting(shuttingDown)
        guard !pending.isEmpty else { return }
        shuttingDown.formUnion(pending)
        shutdownMessage = nil
        do {
            let refused = try await provider.shutdown(deviceIDs: pending.sorted()).filter { [.refused, .unresolved].contains($0.outcome) }
            shutdownMessage = refused.isEmpty ? nil : refused.map { "\($0.name ?? $0.deviceID): \($0.reason ?? "refused")" }.joined(separator: "\n")
        } catch {
            shutdownMessage = error.localizedDescription
        }
        shuttingDown.subtract(pending)
        await refresh()
    }

    public func acknowledgeCrashes(deviceID: String) async {
        do { try await provider.acknowledgeCrashes(deviceID: deviceID) }
        catch { shutdownMessage = error.localizedDescription }
        await refresh()
    }

    public func setDevicesVisible(_ visible: Bool) async {
        includesDevices = visible
        if visible { await refresh() }
    }

    public var copyDetailsText: String {
        var lines = [leaseDetailsText]
        for device in state.devices ?? [] {
            lines.append("Simulator: \(device.name) \(device.id) · \(device.detail)")
            lines.append("  \(device.user)")
            for name in device.waiting { lines.append("  Waiting: \(name)") }
            for process in device.unmanaged { lines.append("  Unmanaged: \(process)") }
        }
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
            if !isReaping, now().timeIntervalSince(lastReap) >= 60 {
                isReaping = true
                lastReap = now()
                Task {
                    try? await provider.reap()
                    isReaping = false
                }
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    private var leaseDetailsText: String {
        switch state.kind {
        case .free:
            return "Simulator available"
        case .metadataError:
            var lines = ["Simulator metadata error", state.error ?? "Unknown error"]
            for job in state.running { lines.append("Lane \(job.lane + 1): \(job.headline) · \(job.elapsed)") }
            lines.append("Waiting: \(state.waiters.count)")
            for waiter in state.waiters { lines.append("- \(waiter.headline) · \(waiter.elapsed)") }
            return lines.joined(separator: "\n")
        case .leased:
            var lines = [
                "Owner: \(state.ownerName ?? "Unknown")",
                "Project: \(state.projectAndSource ?? "Unknown")",
                "Command: \(state.command ?? "Unknown")",
                "Elapsed: \(state.elapsed ?? "Unknown")\(state.typicalDuration.map { " (\($0))" } ?? "")",
                "Waiting: \(state.waiters.count)",
            ]
            if let idle = state.nativeIdle { lines.append(idle) }
            for waiter in state.waiters {
                lines.append("- \(waiter.name)")
                lines.append(
                    "  \(waiter.projectAndSource) · \(waiter.elapsed)\(waiter.estimate.map { " · \($0)" } ?? "")"
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
