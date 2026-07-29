import Foundation
import SimLeaseCore

enum CleanupFormatting {
    static func review(_ review: CleanupReview) -> String {
        guard let plan = review.plan else {
            return "No stale simulator storage is eligible\n"
        }
        var lines = ["Devices"]
        lines.append(contentsOf: items(plan.devices))
        lines.append("Runtimes")
        lines.append(contentsOf: items(plan.runtimes))
        lines.append("Protected")
        lines.append(contentsOf: plan.protected.map {
            "  - \($0.target.name) [\($0.target.identifier)] — \($0.explanation)"
        })
        lines.append("Estimated: \(bytes(plan.estimatedBytes))")
        lines.append("Plan ID: \(plan.id)")
        lines.append("Expires: \(ISO8601DateFormatter().string(from: plan.expiresAt))")
        lines.append("Apply: simlease clean apply \(plan.id)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func result(_ result: CleanupResult) -> String {
        var lines = result.items.map {
            "\($0.outcome.rawValue): \($0.target.name) [\($0.target.identifier)] — \($0.message)"
        }
        lines.append("Estimated: \(bytes(result.estimatedBytes))")
        if let before = result.availableBytesBefore,
           let after = result.availableBytesAfter {
            lines.append("Available: \(bytes(before)) → \(bytes(after))")
        }
        return lines.joined(separator: "\n") + "\n"
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
