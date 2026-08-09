import Foundation
import SimLeaseCore

enum LaneFormatting {
    static func acquire(_ result: LaneAcquireResult) -> String {
        guard let lane = result.lane,
              let descriptor = result.environment["SIMLEASE_LANE_FILE"] else {
            return "SimLease: no lane acquired\n"
        }
        var arguments = result.xcodebuildArguments
        if let resultBundlePath = result.resultBundlePath {
            arguments += ["-resultBundlePath", resultBundlePath]
        }
        let renderedArguments = arguments.enumerated().map { index, value in
            index.isMultiple(of: 2) ? value : shellQuote(value)
        }.joined(separator: " ")
        return """
        Acquired \(lane.laneID)
        UDID: \(lane.udid)
        export SIMLEASE_LANE_FILE=\(doubleQuote(descriptor))
        xcodebuild arguments: \(renderedArguments)
        Result bundle: \(result.resultBundlePath ?? "unavailable")
        Release: \(result.releaseCommand.joined(separator: " "))
        """ + "\n"
    }

    static func capacityFull(_ report: LaneStatusReport) -> String {
        let owners = report.reserved.map {
            let owner = $0.threadTitle ?? $0.threadID ?? $0.project
            return "  \($0.laneID): \(owner) (\($0.project)), UDID \($0.udid)"
        }.joined(separator: "\n")
        return """
        SimLease: observed \(report.reserved.count) reserved lane(s); capacity is \(report.configuration.maxActive).
        No lane allocated. Existing reservations and simulator state were unchanged.
        Current owners:
        \(owners.isEmpty ? "  unavailable" : owners)
        Inspect: simlease lane status
        Retry: rerun the same simlease lane acquire command
        """ + "\n"
    }

    static func unavailable(
        kind: String,
        requested: String,
        available: [String]
    ) -> String {
        let choices = available.isEmpty ? "none" : available.joined(separator: ", ")
        return """
        SimLease: requested \(kind) is unavailable or ambiguous: \(requested)
        Valid local choices: \(choices)
        Retry with --\(kind == "runtime" ? "runtime" : "device-type") <exact-choice>
        """ + "\n"
    }

    static func status(_ report: LaneStatusReport) -> String {
        var lines = [
            "Capacity: \(report.configuration.maxActive)",
            "Available slots: \(report.availableSlots.map(String.init).joined(separator: ", "))",
        ]
        if report.reserved.isEmpty {
            lines.append("Reserved lanes: none")
        } else {
            lines.append("Reserved lanes:")
            lines += report.reserved.map {
                "  \($0.laneID): \($0.project), \($0.deviceTypeName), \($0.runtimeName), UDID \($0.udid)"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func configuration(_ report: LaneConfigurationReport) -> String {
        "Maximum active lanes: \(report.configuration.maxActive) (\(report.reservationCount) reserved)\n"
    }

    static func release(_ result: LaneReleaseResult) -> String {
        "Released \(result.laneID); simulator \(result.udid) is \(result.state) and was not deleted.\n"
    }

    static func lifecyclePlan(_ plan: LaneLifecyclePlan) -> String {
        let target: String
        let apply: String
        switch plan.kind {
        case .recovery:
            target = "lane \(plan.laneID ?? "unknown")"
            apply = "simlease lane recover apply \(plan.id) --lane \(plan.laneID ?? "unknown")"
        case .disposal:
            target = "managed simulator \(plan.fingerprint.udid)"
            apply = "simlease lane dispose apply \(plan.id) --target \(plan.fingerprint.udid)"
        }
        return """
        Reviewed \(plan.kind.rawValue) plan \(plan.id)
        Target: \(target)
        Fingerprint: UDID \(plan.fingerprint.udid), runtime \(plan.fingerprint.runtimeIdentifier), device type \(plan.fingerprint.deviceTypeIdentifier), data \(plan.fingerprint.standardizedDataPath), state \(plan.fingerprint.state)
        Expires: \(ISO8601DateFormatter().string(from: plan.expiresAt))
        No change made.
        Apply: \(apply)
        """ + "\n"
    }

    static func recovery(_ result: LaneReleaseResult) -> String {
        "Recovered \(result.laneID); simulator \(result.udid) is \(result.state), reservation released, and device was not deleted.\n"
    }

    static func disposal(_ result: LaneDisposalResult) -> String {
        result.deleted
            ? "Deleted managed simulator \(result.udid) using plan \(result.planID).\n"
            : "Managed simulator \(result.udid) was not deleted.\n"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func doubleQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
