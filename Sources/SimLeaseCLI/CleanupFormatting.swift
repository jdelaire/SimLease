import Foundation
import SimLeaseCore

enum CleanupFormatting {
    static func review(_ review: CleanupReview) -> String {
        guard let plan = review.plan else {
            return "No eligible Xcode storage cleanup is available\n"
        }
        var lines = ["Simulator Devices"]
        lines.append(contentsOf: items(plan.devices))
        lines.append("Simulator Runtimes")
        lines.append(contentsOf: items(plan.runtimes))
        lines.append("Rebuildable Caches")
        lines.append(
            contentsOf: items(
                plan.storage.filter { $0.riskTier == .rebuildable }
            )
        )
        lines.append("Guarded Storage")
        lines.append(
            contentsOf: items(
                plan.storage.filter { $0.riskTier == .guarded }
            )
        )
        lines.append("Deferred")
        lines.append(
            contentsOf: plan.deferred.isEmpty
                ? ["  None"]
                : plan.deferred.map { "  - \(categoryName($0))" }
        )
        lines.append("Protected")
        lines.append(contentsOf: plan.protected.map {
            "  - \($0.target.name) [\($0.target.identifier)] — \($0.explanation)"
        })
        lines.append("Estimated: \(bytes(plan.estimatedBytes))")
        lines.append("Plan ID: \(plan.id)")
        lines.append("Expires: \(ISO8601DateFormatter().string(from: plan.expiresAt))")
        let defaultTargets = plan.targets.filter(\.selectedByDefault)
        if defaultTargets.isEmpty {
            lines.append(
                "Apply: simlease clean apply \(plan.id) --target <target-id>"
            )
        } else {
            let flags = defaultTargets.map {
                "--target \(shellQuote($0.identifier))"
            }.joined(separator: " ")
            lines.append("Apply: simlease clean apply \(plan.id) \(flags)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func result(_ result: CleanupResult) -> String {
        var lines = [String]()
        for outcome in [
            CleanupItemOutcome.deleted,
            .movedToTrash,
            .skipped,
            .failed,
        ] {
            lines.append(resultTitle(outcome))
            let matching = result.items.filter { $0.outcome == outcome }
            lines.append(
                contentsOf: matching.isEmpty
                    ? ["  None"]
                    : matching.map {
                        "  - \($0.target.name) [\($0.target.identifier)] — \($0.message)"
                    }
            )
        }
        lines.append("Estimated: \(bytes(result.estimatedBytes))")
        if let before = result.availableBytesBefore,
           let after = result.availableBytesAfter {
            lines.append("Available: \(bytes(before)) → \(bytes(after))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func resultTitle(_ outcome: CleanupItemOutcome) -> String {
        switch outcome {
        case .deleted: "Deleted"
        case .movedToTrash: "Moved to Trash"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }

    private static func categoryName(_ category: CleanupCategory) -> String {
        switch category {
        case .simulatorDevice: "Simulator Devices"
        case .simulatorRuntime: "Simulator Runtimes"
        case .temporaryDerivedData: "Temporary DerivedData"
        case .previews: "Xcode Previews"
        case .derivedData: "DerivedData"
        case .swiftBuild: "Swift .build"
        case .resultBundle: "Result Bundles"
        case .archive: "Archives"
        case .deviceSupport: "Device Support"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func items(_ targets: [CleanupTarget]) -> [String] {
        if targets.isEmpty { return ["  None"] }
        return targets.map {
            "  - \($0.name) [\($0.identifier)] — \(optionalBytes($0.sizeBytes))"
        }
    }

    private static func optionalBytes(_ value: Int64?) -> String {
        value.map(bytes) ?? "Unknown"
    }

    private static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}
