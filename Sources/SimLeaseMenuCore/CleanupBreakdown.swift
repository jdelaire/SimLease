import Foundation
import SimLeaseCore

public enum CleanupGroup: Int, CaseIterable, Sendable, Identifiable {
    case simulators
    case buildCaches
    case previews
    case results
    case archives
    case deviceSupport

    public var id: Int { rawValue }

    public init(_ category: CleanupCategory) {
        switch category {
        case .simulatorDevice, .simulatorRuntime, .simulatorDeviceData: self = .simulators
        case .derivedData, .temporaryDerivedData, .swiftBuild: self = .buildCaches
        case .previews: self = .previews
        case .resultBundle: self = .results
        case .archive: self = .archives
        case .deviceSupport: self = .deviceSupport
        }
    }

    public var title: String {
        switch self {
        case .simulators: "Simulators"
        case .buildCaches: "DerivedData & builds"
        case .previews: "Previews"
        case .results: "Result bundles"
        case .archives: "Archives"
        case .deviceSupport: "Device Support"
        }
    }
}

public struct CleanupBreakdown: Equatable, Sendable {
    public struct Segment: Equatable, Sendable, Identifiable {
        public let group: CleanupGroup
        public let bytes: Int64
        public let selectedBytes: Int64
        public var id: Int { group.rawValue }
    }

    public let segments: [Segment]
    public let totalBytes: Int64
    public let selectedBytes: Int64
    public let largestTargetBytes: Int64

    public init(plan: CleanupPlan, selected: Set<String>) {
        let targets = plan.devices + plan.runtimes + plan.storage
        var totals = [CleanupGroup: (Int64, Int64)]()
        for target in targets {
            let size = target.sizeBytes ?? 0
            let group = CleanupGroup(target.category)
            let current = totals[group] ?? (0, 0)
            totals[group] = (current.0 + size, current.1 + (selected.contains(target.identifier) ? size : 0))
        }
        segments = CleanupGroup.allCases.compactMap { group in
            guard let value = totals[group], value.0 > 0 else { return nil }
            return Segment(group: group, bytes: value.0, selectedBytes: value.1)
        }
        totalBytes = segments.reduce(0) { $0 + $1.bytes }
        selectedBytes = segments.reduce(0) { $0 + $1.selectedBytes }
        largestTargetBytes = targets.compactMap(\.sizeBytes).max() ?? 0
    }

    public static func unusedDays(_ target: CleanupTarget, now: Date) -> Int? {
        target.lastUsedAt.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }
}
