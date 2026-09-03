import Foundation
import Dispatch
import Darwin
import SimLeaseCore

public struct CLIConfiguration: Sendable {
    public let paths: LeasePaths
    public let timing: LeaseTiming
    public let standardOutput: @Sendable (String) -> Void
    public let standardError: @Sendable (String) -> Void
    public let cleanupService: (any CleanupServicing)?
    public let laneService: (any LaneServicing)?
    public let updateRunner: (any UpdateRunning)?

    public init(
        paths: LeasePaths,
        timing: LeaseTiming,
        standardOutput: @escaping @Sendable (String) -> Void,
        standardError: @escaping @Sendable (String) -> Void,
        cleanupService: (any CleanupServicing)? = nil,
        laneService: (any LaneServicing)? = nil,
        updateRunner: (any UpdateRunning)? = nil
    ) {
        self.paths = paths
        self.timing = timing
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.cleanupService = cleanupService
        self.laneService = laneService
        self.updateRunner = updateRunner
    }

    public static let production = CLIConfiguration(
        paths: .default,
        timing: .production,
        standardOutput: { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        },
        standardError: { text in
            FileHandle.standardError.write(Data(text.utf8))
        },
        updateRunner: ProcessUpdateRunner(
            updaterURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/lib/simlease/install-release.sh")
        )
    )

    public static func production(
        environment: [String: String]
    ) -> CLIConfiguration {
        #if DEBUG || SIMLEASE_TESTING
        let paths = environment["SIMLEASE_CACHE_ROOT"].map {
            LeasePaths(root: URL(fileURLWithPath: $0, isDirectory: true))
        } ?? .default
        #else
        let paths = LeasePaths.default
        #endif

        return CLIConfiguration(
            paths: paths,
            timing: .production,
            standardOutput: production.standardOutput,
            standardError: production.standardError,
            updateRunner: ProcessUpdateRunner(
                updaterURL: URL(
                    fileURLWithPath: environment["HOME"]
                        ?? FileManager.default.homeDirectoryForCurrentUser.path
                )
                .appendingPathComponent(".local/lib/simlease/install-release.sh")
            )
        )
    }
}

public enum SimLeaseCLI {
    public static func run(
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration = .production
    ) -> Int32 {
        do {
            switch try CommandParser.parse(arguments) {
            case .version:
                configuration.standardOutput(
                    "simlease \(SimLeaseBuild.currentVersion)\n"
                )
                return 0
            case .update:
                guard let runner = configuration.updateRunner else {
                    throw UpdateRunnerError.missingUpdater
                }
                return try runner.run(arguments: [
                    "--current-version",
                    SimLeaseBuild.currentVersion.description,
                ])
            case .status(let json):
                return try runStatus(json: json, configuration: configuration)
            case .name(let title):
                return try runName(
                    title: title,
                    environment: environment,
                    configuration: configuration
                )
            case .hold(let title, let project):
                return try runHold(
                    title: title,
                    project: project,
                    arguments: arguments,
                    configuration: configuration
                )
            case .doctor(let json):
                return try runDoctor(
                    json: json,
                    arguments: arguments,
                    environment: environment,
                    configuration: configuration
                )
            case .wait(let timeout, let json):
                return try runWait(
                    timeout: timeout,
                    json: json,
                    configuration: configuration
                )
            case .cleanPlan(let json):
                return try runCleanPlan(
                    json: json,
                    arguments: arguments,
                    environment: environment,
                    configuration: configuration
                )
            case .cleanApply(let id, let targetIDs, let json):
                return try runCleanApply(
                    id: id,
                    targetIDs: targetIDs,
                    json: json,
                    arguments: arguments,
                    environment: environment,
                    configuration: configuration
                )
            case .laneAcquire(let project, let deviceType, let runtime, let json):
                return try runLaneAcquire(
                    project: project,
                    deviceType: deviceType,
                    runtime: runtime,
                    json: json,
                    arguments: arguments,
                    environment: environment,
                    configuration: configuration
                )
            case .laneStatus(let json):
                return try runLaneStatus(
                    json: json,
                    arguments: arguments,
                    environment: environment,
                    configuration: configuration
                )
            case .laneConfig(let maxActive, let json):
                return try runLaneConfig(
                    maxActive: maxActive,
                    json: json,
                    arguments: arguments,
                    environment: environment,
                    configuration: configuration
                )
            case .laneRelease(let json):
                return try runLaneRelease(
                    json: json,
                    arguments: arguments,
                    environment: environment,
                    configuration: configuration
                )
            case .laneRecoverPlan(let laneID, let json):
                return try runLaneRecoveryPlan(
                    laneID: laneID,
                    json: json,
                    environment: environment,
                    configuration: configuration
                )
            case .laneRecoverApply(let planID, let laneID, let json):
                return try runLaneRecoveryApply(
                    planID: planID,
                    laneID: laneID,
                    json: json,
                    environment: environment,
                    configuration: configuration
                )
            case .laneDisposePlan(let udid, let json):
                return try runLaneDisposalPlan(
                    udid: udid,
                    json: json,
                    environment: environment,
                    configuration: configuration
                )
            case .laneDisposeApply(let planID, let udid, let json):
                return try runLaneDisposalApply(
                    planID: planID,
                    udid: udid,
                    json: json,
                    environment: environment,
                    configuration: configuration
                )
            case .shim(let invocation):
                return try runShim(
                    invocation: invocation,
                    environment: environment,
                    configuration: configuration
                )
            }
        } catch CommandParserError.usage {
            configuration.standardError(
                "Usage: simlease <status|name|hold|doctor|wait|lane|clean|update|--version>\n"
            )
            return 64
        } catch UpdateRunnerError.missingUpdater {
            configuration.standardError(
                "SimLease: updater unavailable; reinstall SimLease from GitHub\n"
            )
            return 69
        } catch CleanupServiceError.plan(let error) {
            configuration.standardError("SimLease: cleanup plan unavailable: \(error)\n")
            return 73
        } catch CleanupServiceError.inventory(let error) {
            configuration.standardError("SimLease: simulator inventory failed: \(error)\n")
            return 74
        } catch CleanupServiceError.leaseBusy(let status) {
            configuration.standardError(busyMessage(status))
            return 75
        } catch LaneLockError.timedOut {
            configuration.standardError("SimLease: timed out waiting for simulator lane\n")
            return 75
        } catch let error as LanePlanStoreError {
            configuration.standardError(
                "SimLease: refused lane lifecycle plan: \(error)\n"
            )
            return 76
        } catch let error as LaneServiceError {
            switch error {
            case .capacityFull:
                configuration.standardError("SimLease: simulator lane capacity is full\n")
                return 75
            case .targetMismatch(let expected, let actual):
                configuration.standardError("SimLease: refused unsafe lane operation: \(error)\n")
                configuration.standardError(
                    "SimLease: fix: target lane UDID \(expected)\(actual.map { " (got \($0))" } ?? ""); xcodebuild needs -destination \"platform=iOS Simulator,id=\(expected)\", simctl needs UDID \(expected), axe needs --udid \(expected)\n"
                )
                return 76
            case .derivedDataMismatch(let expected, let actual):
                configuration.standardError("SimLease: refused unsafe lane operation: \(error)\n")
                configuration.standardError(
                    "SimLease: fix: pass -derivedDataPath \(expected)\(actual.map { " (got \($0))" } ?? "")\n"
                )
                return 76
            case .laneOwnershipMismatch, .globalMutationBusy,
                 .laneRecoveryTooRecent, .unsupportedAXeTargeting,
                 .recoveryRequired:
                configuration.standardError("SimLease: refused unsafe lane operation: \(error)\n")
                return 76
            case .runtimeUnavailable, .deviceTypeUnavailable,
                 .invalidLaneDescriptor, .metadataError:
                configuration.standardError("SimLease: lane metadata unavailable: \(error)\n")
                return 74
            }
        } catch ExecutableResolutionError.notFound(let name) {
            configuration.standardError("SimLease: underlying executable not found: \(name)\n")
            return 127
        } catch LeaseAcquisitionError.timedOut {
            configuration.standardError("SimLease: timed out waiting for simulator lease\n")
            return 75
        } catch LeaseAcquisitionError.cancelled(let signal) {
            return 128 + signal
        } catch {
            configuration.standardError("SimLease: \(error)\n")
            return 74
        }
    }

    static func writeJSON<Value: Encodable>(
        _ value: Value,
        configuration: CLIConfiguration
    ) throws {
        let data = try JSONEncoder.simLease.encode(value)
        configuration.standardOutput(String(decoding: data, as: UTF8.self) + "\n")
    }
}
