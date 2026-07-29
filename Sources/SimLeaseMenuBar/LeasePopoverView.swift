import AppKit
import SwiftUI
import SimLeaseMenuCore

struct LeasePopoverPresentation: Equatable {
    let title: String
    let description: String

    init(state: MenuDisplayState) {
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

struct LeasePopoverView: View {
    @ObservedObject var viewModel: MenuViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusContent
            Divider()
            cleanupAction
            Divider()
            footerActions
        }
        .padding(16)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.15), value: viewModel.state.kind)
        .task {
            await viewModel.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                await viewModel.refresh()
            }
        }
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

            Text("Waiting · \(viewModel.state.waiterNames.count)")
                .font(.subheadline.weight(.semibold))

            if !viewModel.state.waiterNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(
                        Array(viewModel.state.waiterNames.enumerated()),
                        id: \.offset
                    ) { _, name in
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(name)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Waiting tasks")
            }
        }
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
        switch viewModel.state.kind {
        case .free: .green
        case .leased: .orange
        case .metadataError: .red
        }
    }
}
