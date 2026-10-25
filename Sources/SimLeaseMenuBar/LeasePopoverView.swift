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
            title = state.laneBars.isEmpty ? "Status unavailable" : "Lanes need attention"
            description = state.laneBars.isEmpty ? state.error ?? "" : "\(state.running.count) running · \(state.waiters.count) waiting"
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
                    ForEach(viewModel.state.alerts) { alert in
                        AlertCard(alert: alert) { id in Task { await viewModel.acknowledgeCrashes(deviceID: id) } }
                    }
                    if !viewModel.state.laneBars.isEmpty {
                        lanes
                    }
                    if !viewModel.state.waiters.isEmpty { queue }
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
        .frame(width: 380)
        .animation(.easeInOut(duration: 0.15), value: viewModel.state.kind)
        .onAppear { Task { await viewModel.setDevicesVisible(true) } }
        .onDisappear { Task { await viewModel.setDevicesVisible(false) } }
    }

    private var header: some View {
        let presentation = LeasePopoverPresentation(state: viewModel.state)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(statusColor.opacity(0.18))
                    Image(systemName: statusSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.title)
                        .font(.headline)
                    Text(presentation.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if let headroom = viewModel.state.headroom, headroom.laneLimit > 1 {
                    gatePill(headroom)
                }
            }
            if let headroom = viewModel.state.headroom {
                HeadroomGauges(headroom: headroom)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func gatePill(_ headroom: HeadroomDisplay) -> some View {
        let color = headroom.open ? ProjectColors.good : ProjectColors.warning
        return Text(headroom.open ? "Lanes open" : "Extra lane closed")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .help(headroom.reason.map { "Extra lanes closed: \($0)" } ?? "Headroom allows extra lanes")
    }

    private var lanes: some View {
        let state = viewModel.state
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: state.laneBars.count > 1 ? "Lanes" : "Lane")
            LaneBarsView(bars: state.laneBars)
            ForEach(state.running) { job in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(ProjectColors.color(for: job.project)).frame(width: 8, height: 8)
                    Text(job.headline)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .help("\(job.headline) · \(job.subheadline)")
                    Text(job.subheadline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(job.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                        .help(job.command)
                }
            }
        }
    }

    private var queue: some View {
        let waiters = viewModel.state.waiters
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Up next · \(waiters.count)")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(waiters.enumerated()), id: \.element.id) { index, waiter in
                    if index > 0 { Divider().padding(.leading, 28) }
                    QueueRow(index: index, waiter: waiter)
                }
            }
            .card(vertical: 4)
        }
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
            FooterIcon(symbol: "chart.bar.xaxis", help: "Open Dashboard") {
                presentCleanupWindow { openWindow(id: "dashboard") }
            }
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
        case .free: ProjectColors.good
        case .leased: .blue
        case .metadataError: ProjectColors.critical
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
    let onAcknowledge: (String) -> Void

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
                HStack(spacing: 12) {
                    if let id = alert.acknowledgeDeviceID {
                        Button("Allow retries") { onAcknowledge(id) }
                            .controlSize(.small)
                            .help("Clears the block for this simulator. Another critical service crash or repeated app crashes block it again.")
                    }
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
    @State private var selectedID: String?

    private var unused: [DeviceDisplayItem] {
        devices.filter { $0.canShutDown && !shuttingDown.contains($0.id) }
    }

    private var selected: DeviceDisplayItem? {
        devices.first { $0.id == selectedID }
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
            if devices.isEmpty {
                Text("No booted or reserved simulators")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .card()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(devices) { device in
                        PhoneTile(device: device, selected: device.id == selectedID)
                            .onTapGesture { selectedID = selectedID == device.id ? nil : device.id }
                    }
                }
                if let device = selected { detail(device) }
            }
        }
        .onChange(of: devices) { _, _ in confirming = [] }
    }

    private func detail(_ device: DeviceDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(device.name) · \(device.runtime)")
                    .font(.callout.weight(.semibold))
                Spacer()
                if shuttingDown.contains(device.id) {
                    ProgressView().controlSize(.mini)
                } else if device.canShutDown {
                    Button {
                        confirming = [device]
                    } label: {
                        Label("Shut Down", systemImage: "power")
                    }
                    .controlSize(.small)
                    .disabled(!confirming.isEmpty)
                }
            }
            Text(roleLine(device))
                .font(.caption)
                .foregroundStyle(.secondary)
            if device.runtimeStale {
                Label("Runtime older than Xcode SDK", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if device.crashBlocked {
                Label("Crash blocked", systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(ProjectColors.critical)
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
            }
            Text(device.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .card()
    }

    private func roleLine(_ device: DeviceDisplayItem) -> String {
        switch device.reservation {
        case .owned: "\(device.lane.map { "Lane \($0 + 1) job" } ?? "In the current job") · shuts down after"
        case .borrowed: "\(device.lane.map { "Lane \($0 + 1) job" } ?? "In the current job") · stays running after"
        case .warm: device.user
        case .unreserved: device.state == "Booted" ? "Booted outside SimLease" : "Shut down"
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
                    guard !ids.isEmpty, ids.allSatisfy({ id in unused.contains { $0.id == id } }) else { return }
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
