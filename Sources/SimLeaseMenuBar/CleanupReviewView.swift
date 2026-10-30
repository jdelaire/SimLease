import SwiftUI
import SimLeaseCore
import SimLeaseMenuCore

struct CleanupReviewView: View {
    @ObservedObject var viewModel: CleanupViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var guardedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Xcode Storage")
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
                    Text("\(bytes(review.estimatedBytes)) can be reclaimed")
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
                let breakdown = CleanupBreakdown(plan: plan, selected: viewModel.selectedTargetIDs)
                VStack(alignment: .leading, spacing: 12) {
                    DiskBar(available: plan.availableBytesBefore, reclaim: breakdown.selectedBytes)
                    BreakdownBar(breakdown: breakdown)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("Freed \(bytes(max(0, after - before)))")
                        .font(.title2.weight(.semibold))
                    DiskBar(available: before, reclaim: max(0, after - before), label: "Before \(bytes(before)) free · now \(bytes(after)) free")
                    HStack(spacing: 8) {
                        outcomeChip("Deleted", result.items.filter { $0.outcome == .deleted }.count, ProjectColors.good)
                        outcomeChip("Trash", result.items.filter { $0.outcome == .movedToTrash }.count, .blue)
                        outcomeChip("Skipped", result.items.filter { $0.outcome == .skipped }.count, .secondary)
                        outcomeChip("Failed", result.items.filter { $0.outcome == .failed }.count, ProjectColors.critical)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
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
        VStack(alignment: .leading, spacing: 6) {
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
            VStack(alignment: .leading, spacing: 0) {
                if targets.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
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
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
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
            TargetRow(target: target, largest: largestBytes, detail: targetDetail(target))
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 7)
    }

    private var largestBytes: Int64 {
        guard case .review(let review) = viewModel.state, let plan = review.plan else {
            if case .applying(let review) = viewModel.state, let plan = review.plan {
                return CleanupBreakdown(plan: plan, selected: []).largestTargetBytes
            }
            return 0
        }
        return CleanupBreakdown(plan: plan, selected: []).largestTargetBytes
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
        if let date = target.lastUsedAt {
            components.append(
                "last used \(date.formatted(date: .abbreviated, time: .omitted))"
            )
        }
        return components.joined(separator: " · ")
    }

    private func outcomeChip(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) \(count)").font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .opacity(count == 0 ? 0.5 : 1)
    }

    private func totalBytes(_ targets: [CleanupTarget]) -> Int64 {
        targets.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
    }

    private func categoryName(_ category: CleanupCategory) -> String {
        switch category {
        case .simulatorDevice: "Simulator devices"
        case .simulatorRuntime: "Simulator runtimes"
        case .simulatorDeviceData: "Simulator caches & logs"
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

private func formatBytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: value)
}

struct DiskBar: View {
    let available: Int64?
    let reclaim: Int64
    var label: String?

    private var capacity: Int64? {
        let url = FileManager.default.homeDirectoryForCurrentUser
        return (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).map(Int64.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let capacity, capacity > 0, let available {
                let free = Double(available) / Double(capacity)
                let gain = min(Double(reclaim) / Double(capacity), 1 - free)
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.45))
                            .frame(width: max(4, proxy.size.width * (1 - free - gain)))
                        if gain > 0 {
                            RoundedRectangle(cornerRadius: 4).fill(ProjectColors.good)
                                .frame(width: max(4, proxy.size.width * gain))
                        }
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                    }
                }
                .frame(height: 14)
                HStack(spacing: 14) {
                    legend(Color.secondary.opacity(0.45), "Used")
                    if reclaim > 0 { legend(ProjectColors.good, "Reclaimed \(formatBytes(reclaim))") }
                    legend(Color.primary.opacity(0.15), "Free \(formatBytes(available))")
                    Spacer()
                    Text(label ?? "\(formatBytes(capacity)) disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Selected \(formatBytes(reclaim))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption)
        }
    }
}

struct BreakdownBar: View {
    let breakdown: CleanupBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reclaimable by kind · \(formatBytes(breakdown.selectedBytes)) of \(formatBytes(breakdown.totalBytes)) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(breakdown.segments) { segment in
                        let width = proxy.size.width * CGFloat(segment.bytes) / CGFloat(max(1, breakdown.totalBytes))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(ProjectColors.color(slot: segment.group.rawValue).opacity(0.3))
                            RoundedRectangle(cornerRadius: 4).fill(ProjectColors.color(slot: segment.group.rawValue))
                                .frame(width: max(0, width * CGFloat(segment.selectedBytes) / CGFloat(max(1, segment.bytes))))
                        }
                        .frame(width: max(3, width))
                        .help("\(segment.group.title): \(formatBytes(segment.selectedBytes)) of \(formatBytes(segment.bytes)) selected")
                    }
                }
            }
            .frame(height: 18)
            FlowLegend(segments: breakdown.segments)
        }
    }
}

private struct FlowLegend: View {
    let segments: [CleanupBreakdown.Segment]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(segments) { segment in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(ProjectColors.color(slot: segment.group.rawValue)).frame(width: 9, height: 9)
                    Text("\(segment.group.title) \(formatBytes(segment.bytes))").font(.caption)
                }
            }
        }
    }
}

struct TargetRow: View {
    let target: CleanupTarget
    let largest: Int64
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(ProjectColors.color(slot: CleanupGroup(target.category).rawValue))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(target.name).lineLimit(1).help(target.name)
                    if let days = CleanupBreakdown.unusedDays(target, now: Date()), days >= 7 {
                        tag("unused \(days) d", .secondary)
                    }
                    tag(target.action == .moveToTrash ? "Trash" : "Delete", target.action == .moveToTrash ? .orange : .secondary)
                }
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule().fill(ProjectColors.color(slot: CleanupGroup(target.category).rawValue).opacity(0.8))
                            .frame(width: proxy.size.width * CGFloat(target.sizeBytes ?? 0) / CGFloat(max(1, largest)))
                    }
                }
                .frame(height: 4)
            }
            Text(target.sizeBytes.map(formatBytes) ?? "?")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 64, alignment: .trailing)
        }
    }

    private var symbol: String {
        switch target.kind {
        case .device: "iphone"
        case .runtime: "cube"
        case .deviceData: "internaldrive"
        case .filesystem: CleanupGroup(target.category) == .archives ? "archivebox" : "folder"
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}
