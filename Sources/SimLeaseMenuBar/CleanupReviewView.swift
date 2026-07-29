import SwiftUI
import SimLeaseCore
import SimLeaseMenuCore

struct CleanupReviewView: View {
    @ObservedObject var viewModel: CleanupViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Simulator Cleanup")
                .font(.title.bold())

            content
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            Spacer()
            ProgressView("Reviewing simulator storage…")
                .frame(maxWidth: .infinity)
            Spacer()
        case .error(let message):
            Spacer()
            ContentUnavailableView(
                "Unable to review cleanup",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            Button("Try Again") {
                Task { await viewModel.load() }
            }
            .frame(maxWidth: .infinity)
            Spacer()
        case .review(let review):
            reviewContent(review, applying: false)
        case .applying(let review):
            reviewContent(review, applying: true)
        case .result(let result):
            resultContent(result)
        }
    }

    private func reviewContent(
        _ review: CleanupReview,
        applying: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated reclaimable: \(bytes(review.estimatedBytes))")
                .font(.headline)

            if let plan = review.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        targetSection("Devices", targets: plan.devices)
                        targetSection("Runtimes", targets: plan.runtimes)
                        protectedSection(plan.protected)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                Text("Confirmation ID: \(plan.id)")
                    .font(.headline.monospaced())
                TextField("Type \(plan.id) to confirm", text: $viewModel.confirmationText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(applying)
            } else {
                ContentUnavailableView(
                    "No stale simulator storage is eligible",
                    systemImage: "checkmark.circle"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error = viewModel.error {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Cancel") {
                    dismissWindow(id: "cleanup")
                }
                Spacer()
                Button(applying ? "Applying…" : "Apply Cleanup") {
                    Task { await viewModel.apply() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canApply || applying)
            }
        }
    }

    private func resultContent(_ result: CleanupResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let before = result.availableBytesBefore,
               let after = result.availableBytesAfter {
                Text("Available space: \(bytes(before)) → \(bytes(after))")
                    .font(.headline)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    resultSection("Deleted", outcome: .deleted, result: result)
                    resultSection("Skipped", outcome: .skipped, result: result)
                    resultSection("Failed", outcome: .failed, result: result)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") {
                    dismissWindow(id: "cleanup")
                }
            }
        }
    }

    private func targetSection(
        _ title: String,
        targets: [CleanupTarget]
    ) -> some View {
        DisclosureGroup("\(title) (\(targets.count))") {
            ForEach(targets, id: \.identifier) { target in
                targetRow(target, detail: optionalBytes(target.sizeBytes))
            }
        }
    }

    private func protectedSection(
        _ targets: [ProtectedCleanupTarget]
    ) -> some View {
        DisclosureGroup("Protected (\(targets.count))") {
            ForEach(
                Array(targets.enumerated()),
                id: \.offset
            ) { _, protected in
                targetRow(
                    protected.target,
                    detail: protected.explanation
                )
            }
        }
    }

    private func resultSection(
        _ title: String,
        outcome: CleanupItemOutcome,
        result: CleanupResult
    ) -> some View {
        let items = result.items.filter { $0.outcome == outcome }
        return DisclosureGroup("\(title) (\(items.count))") {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                targetRow(item.target, detail: item.message)
            }
        }
    }

    private func targetRow(
        _ target: CleanupTarget,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(target.name)
                .lineLimit(1)
                .help(target.name)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func optionalBytes(_ value: Int64?) -> String {
        value.map(bytes) ?? "Unknown"
    }

    private func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}
