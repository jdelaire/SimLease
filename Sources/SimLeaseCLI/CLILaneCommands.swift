import Foundation
import SimLeaseCore

extension SimLeaseCLI {
    static func runLaneAcquire(
        project: String,
        deviceType: String,
        runtime: String,
        json: Bool,
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let service = try laneService(
            environment: environment,
            configuration: configuration
        )
        let identity = try laneIdentity(
            arguments: arguments,
            environment: environment,
            configuration: configuration
        )
        do {
            let result = try service.acquire(
                request: LaneAcquireRequest(
                    project: project,
                    deviceType: deviceType,
                    runtime: runtime
                ),
                identity: identity
            )
            try writeLaneResult(
                result,
                json: json,
                human: LaneFormatting.acquire,
                configuration: configuration
            )
            return 0
        } catch LaneServiceError.capacityFull(let report) {
            let result = LaneAcquireResult(
                state: .capacityFull,
                lane: nil,
                environment: [:],
                xcodebuildArguments: [],
                derivedDataPath: nil,
                resultBundlePath: nil,
                releaseCommand: [],
                nextActions: report.reserved.map {
                    let owner = $0.threadTitle ?? $0.threadID ?? $0.project
                    return "wait for \($0.laneID): \(owner) (\($0.project))"
                } + ["simlease lane status", "retry the acquire command"]
            )
            if json {
                try writeJSON(result, configuration: configuration)
            } else {
                configuration.standardError(LaneFormatting.capacityFull(report))
            }
            return 75
        } catch LaneServiceError.runtimeUnavailable(let requested, let available) {
            configuration.standardError(
                LaneFormatting.unavailable(
                    kind: "runtime",
                    requested: requested,
                    available: available
                )
            )
            return 74
        } catch LaneServiceError.deviceTypeUnavailable(let requested, let available) {
            configuration.standardError(
                LaneFormatting.unavailable(
                    kind: "device type",
                    requested: requested,
                    available: available
                )
            )
            return 74
        }
    }

    static func runLaneStatus(
        json: Bool,
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        _ = arguments
        let report = try laneService(
            environment: environment,
            configuration: configuration
        ).status(now: Date())
        if json {
            try writeJSON(report, configuration: configuration)
        } else {
            configuration.standardOutput(LaneFormatting.status(report))
        }
        return 0
    }

    static func runLaneConfig(
        maxActive: Int?,
        json: Bool,
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        _ = arguments
        let report = try laneService(
            environment: environment,
            configuration: configuration
        ).configure(maxActive: maxActive)
        if json {
            try writeJSON(report, configuration: configuration)
        } else {
            configuration.standardOutput(LaneFormatting.configuration(report))
        }
        return 0
    }

    static func runLaneRelease(
        json: Bool,
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        guard let descriptorPath = environment["SIMLEASE_LANE_FILE"],
              !descriptorPath.isEmpty else {
            throw CommandParserError.usage
        }
        let identity = try laneIdentity(
            arguments: arguments,
            environment: environment,
            configuration: configuration
        )
        let result = try laneService(
            environment: environment,
            configuration: configuration
        ).release(
            descriptorURL: URL(fileURLWithPath: descriptorPath),
            identity: identity
        )
        if json {
            try writeJSON(result, configuration: configuration)
        } else {
            configuration.standardOutput(LaneFormatting.release(result))
        }
        return 0
    }

    static func runLaneRecoveryPlan(
        laneID: String,
        json: Bool,
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let plan = try laneService(
            environment: environment,
            configuration: configuration
        ).createRecoveryPlan(laneID: laneID, now: Date())
        if json {
            try writeJSON(plan, configuration: configuration)
        } else {
            configuration.standardOutput(LaneFormatting.lifecyclePlan(plan))
        }
        return 0
    }

    static func runLaneRecoveryApply(
        planID: String,
        laneID: String,
        json: Bool,
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let result = try laneService(
            environment: environment,
            configuration: configuration
        ).applyRecovery(planID: planID, laneID: laneID, now: Date())
        if json {
            try writeJSON(result, configuration: configuration)
        } else {
            configuration.standardOutput(LaneFormatting.recovery(result))
        }
        return 0
    }

    static func runLaneDisposalPlan(
        udid: String,
        json: Bool,
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let plan = try laneService(
            environment: environment,
            configuration: configuration
        ).createDisposalPlan(udid: udid, now: Date())
        if json {
            try writeJSON(plan, configuration: configuration)
        } else {
            configuration.standardOutput(LaneFormatting.lifecyclePlan(plan))
        }
        return 0
    }

    static func runLaneDisposalApply(
        planID: String,
        udid: String,
        json: Bool,
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let result = try laneService(
            environment: environment,
            configuration: configuration
        ).applyDisposal(planID: planID, udid: udid, now: Date())
        if json {
            try writeJSON(result, configuration: configuration)
        } else {
            configuration.standardOutput(LaneFormatting.disposal(result))
        }
        return 0
    }

    private static func writeLaneResult(
        _ result: LaneAcquireResult,
        json: Bool,
        human: (LaneAcquireResult) -> String,
        configuration: CLIConfiguration
    ) throws {
        if json {
            try writeJSON(result, configuration: configuration)
        } else {
            configuration.standardOutput(human(result))
        }
    }

    static func laneService(
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> any LaneServicing {
        if let service = configuration.laneService {
            return service
        }
        let metadata = try MetadataStore(paths: configuration.paths)
        let store = try LaneStore(paths: configuration.paths)
        #if DEBUG || SIMLEASE_TESTING
        let xcrunURL = try environment["SIMLEASE_XCRUN_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? ExecutableResolver.resolve(
            name: "xcrun",
            path: environment["PATH"] ?? "/usr/bin:/bin",
            excluding: URL(fileURLWithPath: "/__simlease_no_exclusion__")
        )
        #else
        let xcrunURL = try ExecutableResolver.resolve(
            name: "xcrun",
            path: environment["PATH"] ?? "/usr/bin:/bin",
            excluding: URL(fileURLWithPath: "/__simlease_no_exclusion__")
        )
        #endif
        return LaneService(
            paths: configuration.paths,
            store: store,
            provider: ProcessLaneSimulatorProvider(
                xcrunURL: xcrunURL,
                environment: environment
            ),
            coordinator: LeaseCoordinator(
                paths: configuration.paths,
                store: metadata,
                timing: configuration.timing
            ),
            laneLocks: LaneLockCoordinator(
                paths: configuration.paths,
                timing: configuration.timing
            ),
            planStore: try LanePlanStore(paths: configuration.paths)
        )
    }

    static func laneIdentity(
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> LeaseIdentity {
        let store = try MetadataStore(paths: configuration.paths)
        return try LeaseIdentity.resolve(
            environment: environment,
            cwd: FileManager.default.currentDirectoryPath,
            command: arguments,
            store: store
        )
    }
}
