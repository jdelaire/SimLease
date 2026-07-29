import SwiftUI
import SimLeaseCore
import SimLeaseMenuCore

struct CleanupReviewView: View {
    @ObservedObject var viewModel: CleanupViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var guardedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Xcode Storage Cleanup")
                .font(.title.bold())

            content
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 560)
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            Spacer()
            ProgressView("Reviewing Xcode storage…")
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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Found \(bytes(review.estimatedBytes)) eligible")
                        .font(.headline)
                    if let plan = review.plan {
                        Text(
                            "Scanned \(plan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(applying)
            }

            if let plan = review.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        cleanupSection(
                            "Simulator Storage",
                            systemImage: "iphone.gen3",
                            targets: plan.devices + plan.runtimes
                        )
                        cleanupSection(
                            "Rebuildable Caches",
                            systemImage: "shippingbox",
                            targets: plan.storage.filter {
                                $0.riskTier == .rebuildable
                            }
                        )
                        guardedSection(
                            plan.storage.filter {
                                $0.riskTier == .guarded
                            }
                        )
                        deferredSection(plan.deferred)
                        protectedSection(plan.protected)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Confirmation ID: \(plan.id)")
                            .font(.headline.monospaced())
                        if viewModel.selectedTrashCount > 0 {
                            Text(
                                "Guarded items move to Trash. Space returns after Trash is emptied."
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                }
                TextField("Type \(plan.id) to confirm", text: $viewModel.confirmationText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(applying)
            } else {
                ContentUnavailableView(
                    "No eligible Xcode storage cleanup",
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
                Button(
                    applying ? "Applying…" : viewModel.primaryActionTitle
                ) {
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
                    resultSection(
                        "Moved to Trash",
                        outcome: .movedToTrash,
                        result: result
                    )
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

    private func cleanupSection(
        _ title: String,
        systemImage: String,
        targets: [CleanupTarget]
    ) -> some View {
        GroupBox {
            if targets.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(targets.enumerated()), id: \.element.identifier) {
                        index,
                        target in
                        selectableTargetRow(target)
                        if index < targets.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label(
                    "\(title) · \(bytes(totalBytes(targets)))",
                    systemImage: systemImage
                )
                .font(.headline)
                Spacer()
                Button("Select All") {
                    for target in targets {
                        viewModel.setSelected(
                            true,
                            targetID: target.identifier
                        )
                    }
                }
                .buttonStyle(.link)
                .disabled(targets.isEmpty)
            }
        }
    }

    private func guardedSection(
        _ targets: [CleanupTarget]
    ) -> some View {
        DisclosureGroup(isExpanded: $guardedExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Never selected automatically. Selected items move to Trash.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 6)
                if targets.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(targets.enumerated()), id: \.element.identifier) {
                        index,
                        target in
                        selectableTargetRow(target)
                        if index < targets.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label(
                    "Guarded Storage · \(bytes(totalBytes(targets)))",
                    systemImage: "exclamationmark.shield"
                )
                .font(.headline)
                Spacer()
                Button("Select All") {
                    for target in targets {
                        viewModel.setSelected(
                            true,
                            targetID: target.identifier
                        )
                    }
                }
                .buttonStyle(.link)
                .disabled(targets.isEmpty)
            }
            .foregroundStyle(.orange)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func selectableTargetRow(_ target: CleanupTarget) -> some View {
        Toggle(
            isOn: Binding(
                get: {
                    viewModel.selectedTargetIDs.contains(target.identifier)
                },
                set: {
                    viewModel.setSelected($0, targetID: target.identifier)
                }
            )
        ) {
            targetContent(target, detail: targetDetail(target))
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 7)
    }

    private func protectedSection(
        _ targets: [ProtectedCleanupTarget]
    ) -> some View {
        DisclosureGroup("Protected (\(targets.count))") {
            ForEach(
                Array(targets.enumerated()),
                id: \.offset
            ) { _, protected in
                targetContent(
                    protected.target,
                    detail: protected.explanation
                )
            }
        }
    }

    private func deferredSection(
        _ categories: [CleanupCategory]
    ) -> some View {
        Group {
            if !categories.isEmpty {
                Label(
                    "\(categories.map(categoryName).joined(separator: ", ")) deferred while simulator is leased",
                    systemImage: "hourglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
                targetContent(item.target, detail: item.message)
            }
        }
    }

    private func targetContent(
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

    private func targetDetail(_ target: CleanupTarget) -> String {
        var components = [String]()
        if !target.detail.isEmpty {
            components.append(target.detail)
        } else if !target.runtimeIdentifier.isEmpty {
            components.append(target.runtimeIdentifier)
        }
        components.append(target.sizeBytes.map(bytes) ?? "Unknown size")
        if let date = target.lastUsedAt {
            components.append(
                date.formatted(date: .abbreviated, time: .omitted)
            )
        }
        return components.joined(separator: " · ")
    }

    private func totalBytes(_ targets: [CleanupTarget]) -> Int64 {
        targets.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
    }

    private func categoryName(_ category: CleanupCategory) -> String {
        switch category {
        case .simulatorDevice: "Simulator devices"
        case .simulatorRuntime: "Simulator runtimes"
        case .temporaryDerivedData: "Temporary DerivedData"
        case .previews: "Xcode previews"
        case .derivedData: "DerivedData"
        case .swiftBuild: "Swift build caches"
        case .resultBundle: "Result bundles"
        case .archive: "Archives"
        case .deviceSupport: "Device Support"
        }
    }

    private func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}
