import Charts
import SwiftUI
import SimLeaseCore
import SimLeaseMenuCore

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("SimLease")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Picker("Range", selection: $viewModel.hours) {
                        Text("1h").tag(1)
                        Text("6h").tag(6)
                        Text("24h").tag(24)
                        Text("7d").tag(168)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                if let error = viewModel.error {
                    Text(error).foregroundStyle(.secondary)
                }
                if let summary = viewModel.summary {
                    tiles(summary)
                    panel("Lane timeline", "One block per job, colored by project. Red marks are crashes; hatching is when extra lanes were closed.") {
                        LaneTimeline(summary: summary, since: viewModel.since)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        panel("Memory free", "Extra lanes open at 45% and close below 40%.") {
                            HeadroomChart(samples: summary.samples, value: { $0.memoryFreePercent }, lines: [(45, "opens"), (40, "closes")], since: viewModel.since)
                        }
                        panel("CPU idle", "Extra lanes need at least 35%.") {
                            HeadroomChart(samples: summary.samples, value: { $0.cpuIdlePercent }, lines: [(35, "needed")], since: viewModel.since)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        panel("Crashes by simulator", "Crash reports SimLease attributed to a job, per hour.") {
                            CrashHeatmap(cells: summary.heat)
                        }
                        panel("Projects", "Typical lane time feeds the queue estimates.") {
                            ProjectTable(rows: summary.projects)
                        }
                    }
                } else if viewModel.error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 760, minHeight: 640)
        .task(id: viewModel.hours) { await viewModel.monitor() }
    }

    private func tiles(_ summary: DashboardSummary) -> some View {
        HStack(spacing: 10) {
            tile("Jobs finished", "\(summary.jobsFinished)", "in the selected range")
            tile("Median wait", summary.medianWaitSeconds.map(Self.duration) ?? "–", "queue to start")
            tile("Extra lanes used", summary.extraLaneShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", summary.gateClosedShare.map { "closed \(Int(($0 * 100).rounded()))% for headroom" } ?? "one lane configured")
            tile("Crash blocks", "\(summary.crashBlocks)", summary.crashBlocks == 0 ? "none active" : "simulators blocked now", critical: summary.crashBlocks > 0)
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String, critical: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.semibold).monospacedDigit()).foregroundStyle(critical ? ProjectColors.critical : .primary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func panel<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            content().padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded())) s" : String(format: "%.1f min", seconds / 60)
    }
}

private struct LaneTimeline: View {
    let summary: DashboardSummary
    let since: Date

    var body: some View {
        Chart {
            ForEach(Array(summary.closedIntervals.enumerated()), id: \.offset) { _, interval in
                RectangleMark(xStart: .value("Start", max(interval.lowerBound, since)), xEnd: .value("End", interval.upperBound), y: .value("Lane", "Lane 2"))
                    .foregroundStyle(.gray.opacity(0.18))
            }
            ForEach(summary.timeline) { item in
                BarMark(xStart: .value("Start", item.start), xEnd: .value("End", item.end), y: .value("Lane", item.exclusive ? "Lane 1" : "Lane \(item.lane + 1)"))
                    .foregroundStyle(ProjectColors.color(for: item.project))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .annotation(position: .overlay, alignment: .leading) {
                        Text(item.project).font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                if item.crashes > 0 {
                    PointMark(x: .value("Crash", item.start), y: .value("Lane", item.exclusive ? "Lane 1" : "Lane \(item.lane + 1)"))
                        .symbol(.triangle)
                        .foregroundStyle(ProjectColors.critical)
                        .annotation(position: .top) { Text("\(item.crashes)").font(.caption2).foregroundStyle(ProjectColors.critical) }
                }
            }
        }
        .chartXScale(domain: since...Date())
        .chartYScale(domain: ["Lane 1", "Lane 2", "Lane 3"].prefix(max(1, (summary.timeline.map(\.lane).max() ?? 0) + 1, summary.closedIntervals.isEmpty ? 1 : 2)).map { $0 })
        .frame(height: 140)
    }
}

private struct HeadroomChart: View {
    let samples: [HeadroomRecord]
    let value: (HeadroomRecord) -> Int?
    let lines: [(Int, String)]
    let since: Date

    var body: some View {
        Chart {
            ForEach(samples, id: \.at) { sample in
                if let point = value(sample) {
                    LineMark(x: .value("Time", sample.at), y: .value("Percent", point))
                        .foregroundStyle(ProjectColors.color(slot: 0))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(lines, id: \.0) { line in
                RuleMark(y: .value("Threshold", line.0))
                    .foregroundStyle(line.1 == "closes" ? ProjectColors.warning : ProjectColors.good)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: line.1 == "closes" ? .bottom : .top, alignment: .trailing) { Text("\(line.1) \(line.0)%").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: since...Date())
        .overlay {
            if samples.isEmpty { Text("Collecting samples…").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(height: 150)
    }
}

private struct CrashHeatmap: View {
    let cells: [DashboardSummary.HeatCell]

    var body: some View {
        if cells.isEmpty {
            Text("No attributed crashes in this range")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Chart(cells) { cell in
                RectangleMark(x: .value("Hour", cell.hour, unit: .hour), y: .value("Simulator", cell.device))
                    .foregroundStyle(by: .value("Crashes", cell.count))
                    .annotation(position: .overlay) { Text("\(cell.count)").font(.caption2).foregroundStyle(.white) }
            }
            .chartForegroundStyleScale(range: Gradient(colors: [ProjectColors.color(slot: 0).opacity(0.35), ProjectColors.color(slot: 0)]))
            .chartLegend(.hidden)
            .frame(height: max(80, CGFloat(Set(cells.map(\.device)).count) * 30 + 30))
        }
    }
}

private struct ProjectTable: View {
    let rows: [DashboardSummary.ProjectRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Project")
                Text("Jobs").gridColumnAlignment(.trailing)
                Text("Typical").gridColumnAlignment(.trailing)
                Text("Wait").gridColumnAlignment(.trailing)
                Text("Crashes").gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(ProjectColors.color(for: row.project)).frame(width: 9, height: 9)
                        Text(row.project).lineLimit(1)
                    }
                    Text("\(row.jobs)")
                    Text(DashboardView.duration(row.typicalSeconds))
                    Text(row.medianWaitSeconds.map(DashboardView.duration) ?? "–")
                    Text("\(row.crashes)").foregroundStyle(row.crashes > 0 ? ProjectColors.critical : .primary)
                }
                .font(.callout.monospacedDigit())
            }
            if rows.isEmpty {
                Text("No finished jobs yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
