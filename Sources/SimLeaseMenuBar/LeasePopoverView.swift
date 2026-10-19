import AppKit
import SwiftUI
import SimLeaseMenuCore
import SimLeaseCore

struct LeasePopoverPresentation: Equatable {
    let title: String
    let description: String

    init(state: MenuDisplayState) {
        switch state.kind {
        case .free:
            title = "Simulator free"
            description = "Ready for simulator work"
        case .leased:
            title = "Simulator busy"
            description = state.waiters.isEmpty ? "Nobody waiting" : "\(state.waiters.count) waiting"
        case .metadataError:
            title = "Status unavailable"
            description = state.error ?? ""
        }
    }
}

@MainActor
func presentCleanupWindow(
    openWindow: () -> Void,
    activateApplication: () -> Void = { NSApplication.shared.activate() }
) {
    openWindow()
    activateApplication()
}

@MainActor
func performQuitAction(
    terminateApplication: () -> Void = {
        NSApplication.shared.terminate(nil)
    }
) {
    terminateApplication()
}

struct LeasePopoverView: View {
    @ObservedObject var viewModel: MenuViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.state.alerts) { AlertCard(alert: $0) }
                    if viewModel.state.kind == .leased {
                        nowRunning
                        if !viewModel.state.waiters.isEmpty { queue }
                    }
                    if let devices = viewModel.state.devices {
                        SimulatorSection(
                            devices: devices,
                            shuttingDown: viewModel.shuttingDown,
                            message: viewModel.shutdownMessage,
                            laneBusy: viewModel.state.kind == .leased,
                            onShutDown: { ids in Task { await viewModel.shutdown(ids) } }
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 680)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 360)
        .animation(.easeInOut(duration: 0.15), value: viewModel.state.kind)
        .onAppear { Task { await viewModel.setDevicesVisible(true) } }
        .onDisappear { Task { await viewModel.setDevicesVisible(false) } }
    }

    private var header: some View {
        let presentation = LeasePopoverPresentation(state: viewModel.state)
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.18))
                Image(systemName: statusSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let lanes = viewModel.state.laneSummary {
                    Text(lanes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let elapsed = viewModel.state.elapsed {
                Text(elapsed)
                    .font(.title3.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .help("Time the current job has held the simulator")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var nowRunning: some View {
        let state = viewModel.state
        let multiple = state.running.count > 1 || state.laneSummary != nil
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: state.running.count > 1 ? "Now running · \(state.running.count)" : "Now running")
            ForEach(state.running) { job in
                runningCard(job, devices: (state.devices ?? []).filter { [.owned, .borrowed].contains($0.reservation) && ($0.lane ?? 0) == job.lane }, showLane: multiple)
            }
        }
    }

    private func runningCard(_ job: RunningJobDisplay, devices: [DeviceDisplayItem], showLane: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.headline)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if showLane {
                    Text(job.exclusive ? "All lanes" : "Lane \(job.lane + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                }
                Text(job.elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(job.subheadline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(job.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(job.command)
                .textSelection(.enabled)
            if let typical = job.typicalSeconds, typical > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: min(job.elapsedSeconds / typical, 1))
                        .tint(job.elapsedSeconds > typical ? .orange : .accentColor)
                    Text(job.elapsedSeconds > typical
                         ? "Longer than usual · typically ≈ \(Self.minutes(typical))"
                         : "\(Self.minutes(job.elapsedSeconds)) of ≈ \(Self.minutes(typical)) typical")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !devices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(devices) { device in
                        Label {
                            Text("\(device.name) · \(device.runtime)")
                                + Text(device.reservation == .owned ? "  shuts down after" : "  stays running after")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "iphone")
                                .foregroundStyle(.blue)
                        }
                        .font(.caption)
                        .lineLimit(1)
                        .help(device.id)
                    }
                }
            }
        }
        .card()
    }

    private var queue: some View {
        let waiters = viewModel.state.waiters
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Up next · \(waiters.count)")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(waiters.enumerated()), id: \.element.id) { index, waiter in
                    if index > 0 { Divider().padding(.leading, 28) }
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(waiter.headline)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Text(waiter.estimate ?? waiter.waited)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(([waiter.subheadline] + (waiter.estimate == nil ? [] : [waiter.waited])).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !waiter.targets.isEmpty {
                                Label(waiter.targets.joined(separator: ", "), systemImage: "iphone")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .help(waiterHelp(waiter))
                    .accessibilityElement(children: .combine)
                }
            }
            .card(vertical: 4)
        }
    }

    private func waiterHelp(_ waiter: WaiterDisplayItem) -> String {
        var details = ["\(waiter.projectAndSource) · \(waiter.waited)", waiter.command]
        if let threadID = waiter.threadID { details.append("Thread: \(threadID)") }
        details.append("Path: \(waiter.cwd)")
        return details.joined(separator: "\n")
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                presentCleanupWindow { openWindow(id: "cleanup") }
            } label: {
                Label("Storage Cleanup…", systemImage: "internaldrive")
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens simulator storage cleanup review")
            Spacer()
            FooterIcon(symbol: "doc.on.doc", help: "Copy details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.copyDetailsText, forType: .string)
            }
            FooterIcon(symbol: "arrow.clockwise", help: "Refresh") {
                Task { await viewModel.refresh() }
            }
            FooterIcon(symbol: "power", help: "Quit SimLease") {
                performQuitAction()
            }
        }
        .font(.callout)
    }

    private var statusColor: Color {
        switch viewModel.state.kind {
        case .free: .green
        case .leased: .blue
        case .metadataError: .red
        }
    }

    private var statusSymbol: String {
        switch viewModel.state.kind {
        case .free: "checkmark"
        case .leased: "hourglass"
        case .metadataError: "exclamationmark"
        }
    }

    static func minutes(_ seconds: Double) -> String {
        "\(max(1, Int((seconds / 60).rounded()))) min"
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

private struct FooterIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

private extension View {
    func card(vertical: CGFloat = 10) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AlertCard: View {
    let alert: MenuAlert

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title)
                    .font(.subheadline.weight(.semibold))
                Text(alert.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let label = alert.copyLabel, let text = alert.copyText {
                    Button(label) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(text)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.25)))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch alert.severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch alert.severity {
        case .critical: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

private struct SimulatorSection: View {
    let devices: [DeviceDisplayItem]
    let shuttingDown: Set<String>
    let message: String?
    let laneBusy: Bool
    let onShutDown: ([String]) -> Void
    @State private var confirming: [DeviceDisplayItem] = []

    private var unused: [DeviceDisplayItem] {
        devices.filter { $0.canShutDown && !shuttingDown.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: "Simulators · \(devices.count)")
                Spacer()
                if unused.count > 1 {
                    Button("Shut Down Unused (\(unused.count))") { confirming = unused }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(!confirming.isEmpty)
                }
            }
            if !confirming.isEmpty { confirmation }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                if devices.isEmpty {
                    Text("No booted or reserved simulators")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Divider().padding(.leading, 18) }
                    row(device)
                }
            }
            .card(vertical: 4)
        }
    }

    private func row(_ device: DeviceDisplayItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(device.state == "Booted" ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .help(device.state)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(device.runtime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    chip(device)
                    if shuttingDown.contains(device.id) {
                        ProgressView()
                            .controlSize(.mini)
                    } else if device.canShutDown {
                        Button {
                            confirming = [device]
                        } label: {
                            Image(systemName: "power")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!confirming.isEmpty)
                        .help("Shut down \(device.name)")
                        .accessibilityLabel("Shut down \(device.name)")
                    }
                }
                Text(roleLine(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if device.runtimeStale {
                    Label("Runtime older than Xcode SDK", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if device.crashBlocked {
                    Label("Crash blocked", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ForEach(device.unmanaged, id: \.self) { process in
                    Label("Outside lease · \(process)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !device.waiting.isEmpty {
                    Label("Queued for \(device.waiting.joined(separator: ", "))", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .help("\(device.name) · \(device.runtime)\n\(device.id)\n\(device.user)")
        .accessibilityElement(children: .combine)
    }

    private func roleLine(_ device: DeviceDisplayItem) -> String {
        switch device.reservation {
        case .owned: "\(device.lane.map { "Lane \($0 + 1) job" } ?? "In the current job") · shuts down after"
        case .borrowed: "\(device.lane.map { "Lane \($0 + 1) job" } ?? "In the current job") · stays running after"
        case .warm: device.user
        case .unreserved: device.state == "Booted" ? "Booted outside SimLease" : "Shut down"
        }
    }

    @ViewBuilder
    private func chip(_ device: DeviceDisplayItem) -> some View {
        let style: (text: String, color: Color)? = switch device.reservation {
        case .owned, .borrowed: ("In use", .blue)
        case .warm: ("Warm", .teal)
        case .unreserved: nil
        }
        if let style {
            let color = style.color
            Text(style.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color.opacity(0.15), in: Capsule())
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(confirming.count == 1 ? "Shut down this simulator?" : "Shut down \(confirming.count) simulators?")
                .font(.caption.weight(.semibold))
            ForEach(confirming) { device in
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(device.name) · \(device.runtime)")
                        .font(.caption)
                    Text(device.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("SimLease cannot see Simulator windows or idle device tools. Continue only if nothing uses these simulators.\(laneBusy ? " Shutdown waits for the current job." : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirming = [] }
                Button("Shut Down") {
                    let ids = confirming.map(\.id)
                    confirming = []
                    onShutDown(ids)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
