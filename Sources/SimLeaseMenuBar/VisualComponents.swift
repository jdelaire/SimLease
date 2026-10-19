import AppKit
import SwiftUI
import SimLeaseCore
import SimLeaseMenuCore

enum ProjectColors {
    private static let light: [UInt32] = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x6250d6]
    private static let dark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9]

    static func color(slot: Int) -> Color {
        Color(nsColor: nsColor(slot: slot))
    }

    static func color(for project: String) -> Color {
        color(slot: ProjectPalette.slot(for: project))
    }

    static func nsColor(slot: Int) -> NSColor {
        let index = ((slot % light.count) + light.count) % light.count
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(dark ? Self.dark[index] : Self.light[index])
        }
    }

    static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    static let good = Color(nsColor: rgb(0x0ca30c))
    static let warning = Color(nsColor: rgb(0xfab219))
    static let critical = Color(nsColor: rgb(0xd03b3b))
}

struct HeadroomGauges: View {
    let headroom: HeadroomDisplay

    var body: some View {
        HStack(spacing: 16) {
            if let memory = headroom.memoryFreePercent {
                RingGauge(value: Double(memory) / 100, color: memory >= 45 ? ProjectColors.good : memory >= 40 ? ProjectColors.warning : ProjectColors.critical, label: "\(memory)%", caption: "memory free")
                    .help("Memory free \(memory)%. Extra lanes open at 45% and close below 40%.")
            }
            if let idle = headroom.cpuIdlePercent {
                RingGauge(value: Double(idle) / 100, color: idle >= 30 ? ProjectColors.good : idle >= 20 ? ProjectColors.warning : ProjectColors.critical, label: "\(idle)%", caption: "CPU idle")
                    .help("CPU idle \(idle)%, smoothed over about 3 minutes. Extra lanes open at 30% and close below 20%.")
            }
            if let load = headroom.load {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(load.rounded()))")
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text(headroom.cpus.map { "load · \($0) cores" } ?? "load")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("1-minute load average. Shown for context; it counts threads waiting on disk, so it does not gate extra lanes.")
            }
        }
    }
}

struct RingGauge: View {
    let value: Double
    let color: Color
    let label: String
    let caption: String

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, value)))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.callout.weight(.semibold).monospacedDigit())
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LaneBarsView: View {
    let bars: [LaneBarDisplay]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(bars) { bar in
                HStack(spacing: 10) {
                    Text("Lane \(bar.lane + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(bar.kind == .running ? .secondary : .tertiary)
                        .frame(width: 44, alignment: .leading)
                    LaneBar(bar: bar)
                }
                .help(help(bar))
            }
        }
    }

    private func help(_ bar: LaneBarDisplay) -> String {
        switch bar.kind {
        case .running: "\(bar.title) · \(bar.detail)\(bar.exclusive ? " · holds every lane" : "")"
        case .free: "Free"
        case .closed: "Closed: headroom check"
        case .off: "Not enabled. Raise with simlease config --max-lanes 3"
        }
    }
}

struct LaneBar: View {
    let bar: LaneBarDisplay

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.07))
                if bar.kind == .off || bar.kind == .closed {
                    HatchPattern()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if bar.kind == .running, let project = bar.project {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ProjectColors.color(for: project).opacity(0.9))
                        .frame(width: max(8, proxy.size.width * bar.fraction))
                }
                HStack {
                    Text(bar.title)
                        .font(.caption.weight(bar.kind == .running ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if !bar.detail.isEmpty {
                        Text(bar.detail)
                            .font(.caption.monospacedDigit())
                    }
                }
                .padding(.horizontal, 10)
                .foregroundStyle(bar.kind == .running ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(height: 30)
    }
}

struct HatchPattern: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 8
            }
            context.stroke(path, with: .color(.primary.opacity(0.08)), lineWidth: 3)
        }
    }
}

struct PhoneTile: View {
    let device: DeviceDisplayItem
    let selected: Bool

    private var accent: Color? {
        if device.crashBlocked { return ProjectColors.critical }
        guard [.owned, .borrowed, .warm].contains(device.reservation) else { return nil }
        return device.ownerProject.map(ProjectColors.color(for:)) ?? .accentColor
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 24, height: 40)
                RoundedRectangle(cornerRadius: 3)
                    .fill(device.state == "Booted" ? (accent ?? Color.gray).opacity(0.6) : Color.primary.opacity(0.06))
                    .frame(width: 18, height: 32)
                RoundedRectangle(cornerRadius: 6)
                    .stroke(accent ?? Color.primary.opacity(0.3), lineWidth: 2)
                    .frame(width: 24, height: 40)
            }
            Text(device.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(device.runtime)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent?.opacity(0.8) ?? .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) { badge.padding(4) }
        .contentShape(Rectangle())
        .help("\(device.name) · \(device.runtime) · \(device.state)\n\(device.user)\n\(device.id)")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badge: some View {
        if device.crashBlocked {
            badgeText("!", ProjectColors.critical)
        } else if device.reservation == .warm {
            Image(systemName: "flame.fill").font(.system(size: 9)).foregroundStyle(.orange)
        } else if let lane = device.lane, [.owned, .borrowed].contains(device.reservation) {
            badgeText("L\(lane + 1)", accent ?? .accentColor)
        } else if !device.unmanaged.isEmpty {
            badgeText("?", ProjectColors.warning)
        }
    }

    private func badgeText(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct QueueRow: View {
    let index: Int
    let waiter: WaiterDisplayItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let project = waiter.project {
                        RoundedRectangle(cornerRadius: 2).fill(ProjectColors.color(for: project)).frame(width: 8, height: 8)
                    }
                    Text(waiter.headline).lineLimit(1)
                    if let reason = waiter.reason {
                        Text("· \(reason)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.secondary.opacity(0.6)).frame(width: proxy.size.width * (waiter.progress ?? 0))
                    }
                }
                .frame(height: 4)
            }
            Text(waiter.estimate.map { $0.replacingOccurrences(of: "starts in ", with: "") } ?? waiter.waited)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .help("\(waiter.subheadline) · \(waiter.waited)\n\(waiter.command)")
    }
}
