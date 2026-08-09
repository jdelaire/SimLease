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
                "Usage: simlease <status|name|hold|lane|clean|update|--version>\n"
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
            case .targetMismatch, .derivedDataMismatch,
                 .laneOwnershipMismatch, .globalMutationBusy,
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

    private static func runCleanPlan(
        json: Bool,
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let service = try cleanupService(
            arguments: arguments,
            environment: environment,
            configuration: configuration
        )
        let review = try service.createPlan()
        if json {
            let data = try JSONEncoder.simLease.encode(review)
            configuration.standardOutput(
                String(decoding: data, as: UTF8.self) + "\n"
            )
        } else {
            configuration.standardOutput(CleanupFormatting.review(review))
        }
        return 0
    }

    private static func runCleanApply(
        id: String,
        targetIDs: [String],
        json: Bool,
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let service = try cleanupService(
            arguments: arguments,
            environment: environment,
            configuration: configuration
        )
        let result = try service.apply(
            planID: id,
            selectedTargetIDs: Set(targetIDs)
        )
        if json {
            let data = try JSONEncoder.simLease.encode(result)
            configuration.standardOutput(
                String(decoding: data, as: UTF8.self) + "\n"
            )
        } else {
            configuration.standardOutput(CleanupFormatting.result(result))
        }
        return result.isPartial ? 76 : 0
    }

    private static func runLaneAcquire(
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

    private static func runLaneStatus(
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

    private static func runLaneConfig(
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

    private static func runLaneRelease(
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

    private static func runLaneRecoveryPlan(
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

    private static func runLaneRecoveryApply(
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

    private static func runLaneDisposalPlan(
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

    private static func runLaneDisposalApply(
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

    private static func writeJSON<Value: Encodable>(
        _ value: Value,
        configuration: CLIConfiguration
    ) throws {
        let data = try JSONEncoder.simLease.encode(value)
        configuration.standardOutput(String(decoding: data, as: UTF8.self) + "\n")
    }

    private static func laneService(
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

    private static func laneIdentity(
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

    private static func cleanupService(
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> any CleanupServicing {
        if let service = configuration.cleanupService {
            return service
        }
        let store = try MetadataStore(paths: configuration.paths)
        let coordinator = LeaseCoordinator(
            paths: configuration.paths,
            store: store,
            timing: configuration.timing
        )
        let identity = try LeaseIdentity.resolve(
            environment: environment,
            cwd: FileManager.default.currentDirectoryPath,
            command: arguments,
            store: store
        )
        var laneProtection = LaneProtectionSnapshot.empty
        var forceDeferredSimulatorCleanup = false
        if let handle = try coordinator.tryAcquire(identity: identity) {
            do {
                let laneStore = try LaneStore(paths: configuration.paths)
                let state = try laneStore.readState()
                var derivedDataPaths = Set<String>()
                for reservation in state.reservations {
                    let descriptor = try laneStore.readDescriptor(
                        at: URL(fileURLWithPath: reservation.descriptorPath)
                    )
                    guard descriptor.laneID == reservation.laneID,
                          descriptor.token == reservation.token,
                          descriptor.udid == reservation.udid else {
                        throw LaneServiceError.metadataError(
                            "lane descriptor does not match reservation"
                        )
                    }
                    derivedDataPaths.insert(descriptor.derivedDataPath)
                }
                laneProtection = LaneProtectionSnapshot(
                    reservedDeviceIDs: Set(state.reservations.map(\.udid)),
                    activeDerivedDataPaths: derivedDataPaths,
                    activeResultBundlePaths: state.reservations.isEmpty
                        ? []
                        : [configuration.paths.laneResultBundles.path]
                )
            } catch {
                forceDeferredSimulatorCleanup = true
            }
            handle.release()
        } else {
            forceDeferredSimulatorCleanup = true
        }
        #if DEBUG || SIMLEASE_TESTING
        let xcrunURL: URL
        if let path = environment["SIMLEASE_XCRUN_PATH"] {
            xcrunURL = URL(fileURLWithPath: path)
        } else {
            xcrunURL = try ExecutableResolver.resolve(
                name: "xcrun",
                path: environment["PATH"] ?? "/usr/bin:/bin",
                excluding: URL(
                    fileURLWithPath: "/__simlease_no_exclusion__"
                )
            )
        }
        let psURL = environment["SIMLEASE_PS_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? URL(fileURLWithPath: "/bin/ps")
        let provider = ProcessCleanupInventoryProvider(
            xcrunURL: xcrunURL,
            psURL: psURL,
            environment: environment
        )
        #else
        let xcrunURL = try ExecutableResolver.resolve(
            name: "xcrun",
            path: environment["PATH"] ?? "/usr/bin:/bin",
            excluding: URL(fileURLWithPath: "/__simlease_no_exclusion__")
        )
        let psURL = URL(fileURLWithPath: "/bin/ps")
        let provider = ProcessCleanupInventoryProvider(
            xcrunURL: xcrunURL,
            psURL: psURL,
            environment: environment
        )
        #endif
        #if DEBUG || SIMLEASE_TESTING
        let cleanupHome = environment["SIMLEASE_CLEANUP_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
        let cleanupTemporary = environment["SIMLEASE_CLEANUP_TMP"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        #else
        let cleanupHome = FileManager.default.homeDirectoryForCurrentUser
        let cleanupTemporary = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        )
        #endif
        var workspaceRoots = [URL]()
        if let owner = try? store.readOwner() {
            workspaceRoots.append(
                URL(fileURLWithPath: owner.cwd, isDirectory: true)
            )
        }
        if let waiters = try? store.readWaiters() {
            workspaceRoots.append(
                contentsOf: waiters.map {
                    URL(fileURLWithPath: $0.cwd, isDirectory: true)
                }
            )
        }
        workspaceRoots.append(
            URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        )
        let activeUseProvider = ProcessActiveUseProvider(
            psURL: psURL,
            environment: environment
        )
        let storageProvider = XcodeStorageInventoryProvider(
            homeDirectory: cleanupHome,
            temporaryDirectory: cleanupTemporary,
            workspaceRoots: workspaceRoots,
            activePaths: Array(
                laneProtection.activeDerivedDataPaths
                    .union(laneProtection.activeResultBundlePaths)
            ),
            activeUseProvider: activeUseProvider
        )
        let xcodeRoot = cleanupHome.appending(
            path: "Library/Developer/Xcode",
            directoryHint: .isDirectory
        )
        let fileOperator = CleanupFileOperator(
            allowedRoots: [
                xcodeRoot.appending(path: "DerivedData"),
                xcodeRoot.appending(path: "UserData/Previews"),
                xcodeRoot.appending(path: "Archives"),
                xcodeRoot.appending(path: "iOS DeviceSupport"),
                cleanupTemporary,
            ] + workspaceRoots
        )
        let planner = CleanupPlanner(
            devicesRoot: cleanupHome
                .appendingPathComponent(
                    "Library/Developer/CoreSimulator/Devices",
                    isDirectory: true
                ),
            laneProtection: laneProtection
        )
        let planStore = try CleanupPlanStore(paths: configuration.paths)
        let executor = CleanupExecutor(
            provider: provider,
            planner: planner,
            storageProvider: storageProvider,
            fileOperator: fileOperator
        )
        return CleanupService(
            coordinator: coordinator,
            identity: identity,
            provider: provider,
            planner: planner,
            store: planStore,
            executor: executor,
            storageProvider: storageProvider,
            forceDeferredSimulatorCleanup: forceDeferredSimulatorCleanup
        )
    }

    private static func runStatus(
        json: Bool,
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let coordinator = try makeCoordinator(configuration: configuration)
        let status = try coordinator.status()
        if json {
            let data = try JSONEncoder.simLease.encode(status)
            configuration.standardOutput(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            configuration.standardOutput("\(status.state.rawValue)\n")
        }
        return 0
    }

    private static func runName(
        title: String,
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        guard let threadID = environment["CODEX_THREAD_ID"] else {
            throw CommandParserError.usage
        }
        let store = try MetadataStore(paths: configuration.paths)
        try store.registerThreadName(id: threadID, title: title)
        return 0
    }

    private static func runHold(
        title: String,
        project: String,
        arguments: [String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let store = try MetadataStore(paths: configuration.paths)
        let coordinator = LeaseCoordinator(
            paths: configuration.paths,
            store: store,
            timing: configuration.timing
        )
        let cwd = FileManager.default.currentDirectoryPath
        let identity = LeaseIdentity(
            pid: getpid(),
            cwd: cwd,
            project: project,
            command: arguments,
            source: .manualXcode,
            threadID: nil,
            threadTitle: title
        )
        let signals = SignalLatch()
        let handle = try coordinator.acquire(
            identity: identity,
            onWaitReport: waitReporter(configuration.standardError),
            cancellationSignal: { signals.current }
        )
        let laneStore = try LaneStore(paths: configuration.paths)
        let laneState = try laneStore.readState()
        let highestReservedSlot = laneState.reservations.map(\.slot).max() ?? 0
        let laneHandle = try LaneLockCoordinator(
            paths: configuration.paths,
            timing: configuration.timing
        ).acquireAll(maxSlot: max(
            laneState.configuration.maxActive,
            highestReservedSlot
        ))
        configuration.standardOutput("SimLease: acquired for \(title) (\(project)); press Ctrl-C to release\n")
        while signals.current == nil {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let signal = signals.current ?? SIGINT
        laneHandle.release()
        handle.release()
        return 128 + signal
    }

    private static func runShim(
        invocation: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        guard let invokedPath = invocation.first else {
            throw CommandParserError.usage
        }
        let invokedURL = URL(fileURLWithPath: invokedPath)
        let toolName = invokedURL.lastPathComponent
        let executable = try ExecutableResolver.resolve(
            name: toolName,
            path: environment["PATH"] ?? "",
            excluding: invokedURL.deletingLastPathComponent()
        )
        let childArguments = Array(invocation.dropFirst())
        let decision = ProtectedCommand.classify(invocation: invocation)

        guard decision.requiresLease, environment["SIMLEASE_HELD"] != "1" else {
            return try ChildProcessRunner.run(
                executable: executable,
                arguments: childArguments,
                environment: environment
            ).exitCode
        }

        let metadataStore = try MetadataStore(paths: configuration.paths)
        let coordinator = LeaseCoordinator(
            paths: configuration.paths,
            store: metadataStore,
            timing: configuration.timing
        )
        let identity = try LeaseIdentity.resolve(
            environment: environment,
            cwd: FileManager.default.currentDirectoryPath,
            command: invocation,
            store: metadataStore
        )
        let laneStore = try LaneStore(paths: configuration.paths)
        let descriptorURL = environment["SIMLEASE_LANE_FILE"].map {
            URL(fileURLWithPath: $0)
        }
        let descriptor = try descriptorURL.map { try laneStore.readDescriptor(at: $0) }
        let scope = try LaneCommandPolicy.validate(
            invocation: invocation,
            descriptor: descriptor
        )

        switch scope {
        case .passThrough:
            return try ChildProcessRunner.run(
                executable: executable,
                arguments: childArguments,
                environment: environment
            ).exitCode
        case .lane(let slot):
            guard let descriptorURL, let descriptor,
                  descriptor.slot == slot else {
                throw LaneServiceError.invalidLaneDescriptor(
                    descriptorURL?.path ?? "missing SIMLEASE_LANE_FILE"
                )
            }
            let service = try laneService(
                environment: environment,
                configuration: configuration
            )
            let global = try acquireGlobalLease(
                coordinator: coordinator,
                identity: identity,
                configuration: configuration
            )
            let freshDescriptor: LaneDescriptor
            let laneHandle: LaneLockHandle
            do {
                freshDescriptor = try laneStore.readDescriptor(at: descriptorURL)
                guard freshDescriptor.slot == slot,
                      freshDescriptor.token == descriptor.token else {
                    throw LaneServiceError.laneOwnershipMismatch(
                        laneID: descriptor.laneID
                    )
                }
                laneHandle = try LaneLockCoordinator(
                    paths: configuration.paths,
                    timing: configuration.timing
                ).acquire(slot: slot)
                _ = try service.renew(descriptorURL: descriptorURL, now: Date())
            } catch {
                global.release()
                throw error
            }
            global.release()
            defer { laneHandle.release() }
            return try runProtectedChild(
                executable: executable,
                arguments: childArguments,
                environment: environment
            )
        case .global:
            let global = try acquireGlobalLease(
                coordinator: coordinator,
                identity: identity,
                configuration: configuration
            )
            defer { global.release() }
            let state = try laneStore.readState()
            let highestReservedSlot = state.reservations.map(\.slot).max() ?? 0
            let allLanes = try LaneLockCoordinator(
                paths: configuration.paths,
                timing: configuration.timing
            ).acquireAll(maxSlot: max(
                state.configuration.maxActive,
                highestReservedSlot
            ))
            defer { allLanes.release() }
            if descriptor == nil,
               let reservedTarget = state.reservations.first(where: {
                   LaneCommandPolicy.explicitlyTargets(
                       invocation: invocation,
                       udid: $0.udid
                   )
               }) {
                throw LaneServiceError.laneOwnershipMismatch(
                    laneID: reservedTarget.laneID
                )
            }
            return try runProtectedChild(
                executable: executable,
                arguments: childArguments,
                environment: environment
            )
        }
    }

    private static func acquireGlobalLease(
        coordinator: LeaseCoordinator,
        identity: LeaseIdentity,
        configuration: CLIConfiguration
    ) throws -> LeaseHandle {
        let signals = SignalLatch()
        return try coordinator.acquire(
            identity: identity,
            onWaitReport: waitReporter(configuration.standardError),
            cancellationSignal: { signals.current }
        )
    }

    private static func runProtectedChild(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> Int32 {
        var childEnvironment = environment
        childEnvironment["SIMLEASE_HELD"] = "1"
        return try ChildProcessRunner.run(
            executable: executable,
            arguments: arguments,
            environment: childEnvironment
        ).exitCode
    }

    private static func makeCoordinator(
        configuration: CLIConfiguration
    ) throws -> LeaseCoordinator {
        let store = try MetadataStore(paths: configuration.paths)
        return LeaseCoordinator(
            paths: configuration.paths,
            store: store,
            timing: configuration.timing
        )
    }

    private static func waitReporter(
        _ output: @escaping @Sendable (String) -> Void
    ) -> @Sendable (LeaseStatus) -> Void {
        { status in
            guard let owner = status.owner else {
                output("SimLease: waiting; owner metadata unavailable\n")
                return
            }
            let name = owner.threadTitle
                ?? owner.threadID.map { String($0.prefix(8)) }
                ?? "\(sourceLabel(owner.source)) · \(owner.project)"
            let held = elapsedString(since: owner.acquiredAt)
            output("SimLease: waiting; owner \(name) (\(owner.project)), held \(held)\n")
        }
    }

    private static func busyMessage(_ status: LeaseStatus) -> String {
        guard let owner = status.owner else {
            return "SimLease: simulator lease busy; owner metadata unavailable\n"
        }
        let name = owner.threadTitle
            ?? owner.threadID.map { String($0.prefix(8)) }
            ?? "\(sourceLabel(owner.source)) · \(owner.project)"
        return "SimLease: simulator lease busy; owner \(name) (\(owner.project))\n"
    }

    private static func sourceLabel(_ source: LeaseSource) -> String {
        switch source {
        case .codex: "Codex"
        case .terminal: "Terminal"
        case .manualXcode: "Manual Xcode"
        }
    }

    private static func elapsedString(since date: Date) -> String {
        let total = max(0, Int(Date().timeIntervalSince(date)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private final class SignalLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int32?
    private var sources: [DispatchSourceSignal] = []
    private let previousINT: sig_t?
    private let previousTERM: sig_t?
    private let previousHUP: sig_t?

    init() {
        previousINT = signal(SIGINT, SIG_IGN)
        previousTERM = signal(SIGTERM, SIG_IGN)
        previousHUP = signal(SIGHUP, SIG_IGN)

        sources = [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global()
            )
            source.setEventHandler { [weak self] in
                self?.lock.withLock {
                    if self?.received == nil {
                        self?.received = signalNumber
                    }
                }
            }
            source.resume()
            return source
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
        _ = signal(SIGINT, previousINT)
        _ = signal(SIGTERM, previousTERM)
        _ = signal(SIGHUP, previousHUP)
    }

    var current: Int32? {
        lock.withLock { received }
    }
}
