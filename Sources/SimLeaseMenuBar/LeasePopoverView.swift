import AppKit
import SwiftUI
import SimLeaseMenuCore
import SimLeaseCore

struct LeasePopoverPresentation: Equatable {
    let title: String
    let description: String

    init(state: MenuDisplayState) {
        if state.kind != .metadataError, !state.crashBlocks.isEmpty {
            title = "Repeated simulator crashes"
            description = "New work is blocked. Review the crash cause before allowing another attempt."
            return
        }
        if state.kind != .metadataError, let activity = state.activity {
            if activity.activities.contains(where: { $0.kind == .unmanaged }) {
                title = "Unmanaged simulator work"
                description = "Known simulator commands are running outside SimLease."
                return
            }
            if activity.isIncomplete {
                title = "Simulator audit incomplete"
                description = activity.error ?? "Some process details could not be verified."
                return
            }
            if !activity.activities.isEmpty {
                title = "Simulator ownership unverified"
                description = "A reservation or target match does not prove process ownership."
                return
            }
        }
        switch state.kind {
        case .free:
            title = "Simulator available"
            description = "Ready for simulator testing."
        case .leased:
            title = "Simulator in use"
            description = state.projectAndSource ?? ""
        case .metadataError:
            title = "Simulator status error"
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
        VStack(alignment: .leading, spacing: 12) {
            statusContent
            if let block = viewModel.state.crashBlocks.first {
                Text("\(block.processName) · \(block.deviceID)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if let activity = viewModel.state.activity, !activity.activities.isEmpty || activity.isIncomplete {
                SimulatorActivityNotice(report: activity)
            }
            Divider()
            cleanupAction
            Divider()
            footerActions
        }
        .padding(16)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.15), value: viewModel.state.kind)
        .task { await viewModel.refresh() }
    }

    @ViewBuilder
    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            if viewModel.state.kind == .leased {
                leasedContent
            }
        }
    }

    private var statusHeader: some View {
        let presentation = LeasePopoverPresentation(state: viewModel.state)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: viewModel.state.symbolName)
                .font(.title3)
                .foregroundStyle(statusColor)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.headline)
                    .contentTransition(.opacity)

                Text(presentation.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 8)

            if let elapsed = viewModel.state.elapsed {
                Text(elapsed)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leasedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ownerName = viewModel.state.ownerName {
                Text(ownerName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .help(ownerName)
            }
            if let command = viewModel.state.command {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(command)
            }

            Divider()

            Text("Waiting · \(viewModel.state.waiters.count)")
                .font(.subheadline.weight(.semibold))

            if !viewModel.state.waiters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.state.waiters) { waiter in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(waiter.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(
                                "\(waiter.projectAndSource) · \(waiter.elapsed)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(waiterHelp(waiter))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(waiter.name)
                        .accessibilityValue(waiterHelp(waiter))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Waiting tasks")
            }
        }
    }

    private func waiterHelp(_ waiter: WaiterDisplayItem) -> String {
        var details = [
            "\(waiter.projectAndSource) · \(waiter.elapsed)",
            waiter.command,
        ]
        if let threadID = waiter.threadID {
            details.append("Thread: \(threadID)")
        }
        details.append("Path: \(waiter.cwd)")
        return details.joined(separator: "\n")
    }

    private var cleanupAction: some View {
        Button {
            presentCleanupWindow {
                openWindow(id: "cleanup")
            }
        } label: {
            HStack {
                Label("Review Cleanup…", systemImage: "internaldrive")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens simulator storage cleanup review")
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button {
                performQuitAction()
            } label: {
                Label("Quit", systemImage: "power")
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    viewModel.copyDetailsText,
                    forType: .string
                )
            } label: {
                Label("Copy Details", systemImage: "doc.on.doc")
            }

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .controlSize(.small)
    }

    private var statusColor: Color {
        if viewModel.state.kind == .metadataError { return .red }
        if !viewModel.state.crashBlocks.isEmpty { return .orange }
        if viewModel.state.activity?.activities.isEmpty == false || viewModel.state.activity?.isIncomplete == true {
            return .orange
        }
        switch viewModel.state.kind {
        case .free: return .green
        case .leased: return .orange
        case .metadataError: return .red
        }
    }
}

private struct SimulatorActivityNotice: View {
    let report: SimulatorActivityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(report.activities.prefix(5)) { activity in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(activity.tool) · PID \(activity.process.pid)")
                        .font(.caption.monospaced())
                    switch activity.kind {
                    case .unmanaged: Text("Outside the current lease")
                    case .reservedNative: Text("Native reservation, ownership unverified")
                    case .targetUnknown: Text("Simulator target unverified")
                    }
                }
            }
            if report.activities.count > 5 { Text("\(report.activities.count - 5) more processes") }
            if report.isIncomplete { Text("Some processes could not be inspected.") }
            Text("Snapshots can miss short commands and background daemon work.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .textSelection(.enabled)
    }
}
