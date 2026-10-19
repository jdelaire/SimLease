import AppKit
import SimLeaseMenuCore

enum MenuBarIcon {
    static func image(_ state: MenuBarIconState) -> NSImage {
        let width: CGFloat = {
            if case .lanes(let lanes) = state.shape { return CGFloat(lanes.count) * 10 + CGFloat(max(0, lanes.count - 1)) * 2 }
            return 16
        }()
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
            switch state.shape {
            case .free:
                ProjectColors.rgb(0x0ca30c).setFill()
                NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
            case .crash, .error:
                (state.shape == .crash ? ProjectColors.rgb(0xd03b3b) : ProjectColors.rgb(0xec835a)).setFill()
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: 8, y: 15))
                triangle.line(to: NSPoint(x: 15.5, y: 1.5))
                triangle.line(to: NSPoint(x: 0.5, y: 1.5))
                triangle.close()
                triangle.fill()
                NSColor.white.setFill()
                NSBezierPath(rect: NSRect(x: 7.2, y: 6, width: 1.6, height: 5.5)).fill()
                NSBezierPath(rect: NSRect(x: 7.2, y: 3.2, width: 1.6, height: 1.6)).fill()
            case .ring(let slot, let fraction):
                let rect = NSRect(x: 2.5, y: 2.5, width: 11, height: 11)
                NSColor.tertiaryLabelColor.setStroke()
                let track = NSBezierPath(ovalIn: rect)
                track.lineWidth = 3
                track.stroke()
                ProjectColors.nsColor(slot: slot).setStroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: 8, y: 8), radius: 5.5, startAngle: 90, endAngle: 90 - 360 * max(0.04, min(1, fraction)), clockwise: true)
                arc.lineWidth = 3
                arc.lineCapStyle = .round
                arc.stroke()
            case .lanes(let lanes):
                for (index, lane) in lanes.enumerated() {
                    let rect = NSRect(x: CGFloat(index) * 12 + 0.75, y: 2.75, width: 8.5, height: 10.5)
                    let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
                    switch lane {
                    case .busy(let slot):
                        ProjectColors.nsColor(slot: slot).setFill()
                        path.fill()
                    case .free:
                        NSColor.secondaryLabelColor.setStroke()
                        path.lineWidth = 1.5
                        path.stroke()
                    case .closed:
                        NSColor.tertiaryLabelColor.setStroke()
                        path.lineWidth = 1.5
                        path.setLineDash([2, 2], count: 2, phase: 0)
                        path.stroke()
                    }
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
