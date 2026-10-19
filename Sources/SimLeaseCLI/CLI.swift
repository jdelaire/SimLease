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
    public let updateRunner: (any UpdateRunning)?
    public let deviceManager: (any SimulatorDeviceManaging)?
    public let crashReportDirectory: URL?

    public init(
        paths: LeasePaths,
        timing: LeaseTiming,
        standardOutput: @escaping @Sendable (String) -> Void,
        standardError: @escaping @Sendable (String) -> Void,
        cleanupService: (any CleanupServicing)? = nil,
        updateRunner: (any UpdateRunning)? = nil,
        deviceManager: (any SimulatorDeviceManaging)? = nil,
        crashReportDirectory: URL? = nil
    ) {
        self.paths = paths
        self.timing = timing
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.cleanupService = cleanupService
        self.updateRunner = updateRunner
        self.deviceManager = deviceManager
        self.crashReportDirectory = crashReportDirectory
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
            case .config(let maxLanes):
                if let maxLanes { try LaneConfig.write(LaneConfig(maxLanes: maxLanes), paths: configuration.paths) }
                let config = LaneConfig.read(configuration.paths)
                let output = ConfigOutput(maxLanes: config.maxLanes, gate: config.maxLanes > 1 ? HeadroomGate(paths: configuration.paths).check() : nil)
                configuration.standardOutput(String(decoding: try JSONEncoder.simLease.encode(output), as: UTF8.self) + "\n")
                return 0
            case .update:
                guard let runner = configuration.updateRunner else {
                    throw UpdateRunnerError.missingUpdater
                }
                return try runner.run(arguments: [
                    "--current-version",
                    SimLeaseBuild.currentVersion.description,
                ])
            case .run(let ids, let keepRunning, let keepWarm, let command):
                return try runTask(command: command, deviceIDs: ids, keepRunning: keepRunning, keepWarm: keepWarm, environment: environment, configuration: configuration)
            case .recover:
                let store = try MetadataStore(paths: configuration.paths)
                let identity = try LeaseIdentity.resolve(environment: environment, cwd: FileManager.default.currentDirectoryPath, command: arguments, store: store)
                try taskService(environment: environment, configuration: configuration).recover(identity: identity)
                configuration.standardOutput("SimLease: recovery complete\n")
                return 0
            case .deviceCreate(let name, let type, let runtime):
                let service = try deviceService(arguments: arguments, environment: environment, configuration: configuration)
                let result = try service.create(name: name, deviceType: type, runtime: runtime)
                configuration.standardOutput(String(decoding: try JSONEncoder.simLease.encode(result), as: UTF8.self) + "\n")
                return 0
            case .deviceRepair(let id, let settled, let acknowledge):
                let service = try deviceService(arguments: arguments, environment: environment, configuration: configuration)
                let result = try service.repair(deviceID: id, settled: settled, acknowledgeCrashes: acknowledge)
                configuration.standardOutput(String(decoding: try JSONEncoder.simLease.encode(result), as: UTF8.self) + "\n")
                return 0
            case .deviceRecover:
                try deviceService(arguments: arguments, environment: environment, configuration: configuration).recoverCreation(settled: true)
                configuration.standardOutput("{\"state\":\"recovered\",\"note\":\"Recorded devices were preserved; inspect crash blocks before reuse\"}\n")
                return 0
            case .deviceShutdown(let ids):
                if insideManagedWork(configuration) {
                    throw SimulatorTaskError.commandFailed("simulator shutdown cannot nest inside a managed job or native session")
                }
                let service = try shutdownService(title: "Shut down simulators", arguments: arguments, environment: environment, configuration: configuration)
                let results = try service.shutdown(deviceIDs: ids)
                configuration.standardOutput(String(decoding: try JSONEncoder.simLease.encode(["results": results]), as: UTF8.self) + "\n")
                return results.contains { $0.outcome == .unresolved } ? 75 : 0
            case .deviceAcknowledge(let id):
                let crashes = CrashLoopStore(paths: configuration.paths)
                let blocked = try crashes.read().blocks[id] != nil
                if blocked { try crashes.acknowledge(deviceID: id, at: Date()) }
                configuration.standardOutput("{\"deviceID\":\"\(id)\",\"acknowledged\":\(blocked)}\n")
                return 0
            case .deviceReap:
                if insideManagedWork(configuration) {
                    throw SimulatorTaskError.commandFailed("simulator reaping cannot nest inside a managed job or native session")
                }
                let results = try shutdownService(title: "Reap warm simulators", arguments: arguments, environment: environment, configuration: configuration).reap()
                let output = ReapOutput(busy: results == nil, results: results ?? [])
                configuration.standardOutput(String(decoding: try JSONEncoder.simLease.encode(output), as: UTF8.self) + "\n")
                return output.results.contains { $0.outcome == .unresolved } ? 75 : 0
            case .sessionBegin(let title, let project, let ids, let clientPIDs):
                let id = UUID().uuidString
                let clients = try NativeClientAdmission.capture(pids: clientPIDs)
                let identity = LeaseIdentity(pid: getpid(), cwd: FileManager.default.currentDirectoryPath, project: project, command: arguments, source: .nativeTool, threadID: environment["CODEX_THREAD_ID"], threadTitle: title)
                let executable = arguments[0].contains("/") ? URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath()
                    : try ExecutableResolver.resolve(name: "simlease", path: environment["PATH"] ?? "", excluding: URL(fileURLWithPath: "/dev/null"))
                warnAboutStaleRuntimes(ids, environment: environment, configuration: configuration)
                return try taskService(environment: environment, configuration: configuration).run(
                    executable: executable,
                    arguments: ["__native_wait", id], deviceIDs: ids, keepRunning: false,
                    environment: environment, identity: identity, externalSessionID: id, nativeClients: clients,
                    onStarted: { record in
                        let ready = NativeSessionReady(sessionID: id, pid: record.owner.pid, deviceIDs: record.deviceIDs, ownedDeviceIDs: record.ownedDeviceIDs)
                        configuration.standardOutput(String(decoding: try JSONEncoder().encode(ready), as: UTF8.self) + "\n")
                    }
                )
            case .sessionFinish(let id):
                let store = try MetadataStore(paths: configuration.paths)
                let identity = try LeaseIdentity.resolve(environment: environment, cwd: FileManager.default.currentDirectoryPath, command: arguments, store: store)
                try NativeSessionController(paths: configuration.paths, tasks: taskService(environment: environment, configuration: configuration)).finish(id: id, identity: identity)
                configuration.standardOutput("SimLease: native session cleanup complete\n")
                return 0
            case .nativeWait(let id):
                return try NativeSessionController.waitForAcknowledgment(paths: configuration.paths, id: id, environment: environment)
            case .status(let json, let audit, let devices):
                return try runStatus(json: json, audit: audit, devices: devices, environment: environment, configuration: configuration)
            case .doctor(let json):
                return try CoverageDoctor.run(json: json, environment: environment, configuration: configuration)
            case .name(let title):
                return try runName(
                    title: title,
                    environment: environment,
                    configuration: configuration
                )
            case .hold(let title, let project, let ids, let keepRunning):
                return try runHold(
                    title: title,
                    project: project,
                    deviceIDs: ids,
                    keepRunning: keepRunning,
                    arguments: arguments,
                    environment: environment,
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
            case .shim(let invocation):
                return try runShim(
                    invocation: invocation,
                    environment: environment,
                    configuration: configuration
                )
            }
        } catch CommandParserError.usage {
            configuration.standardError(
                "Usage: simlease <run|session|device|recover|doctor|status|config|name|hold|clean|update|--version>\n"
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
        #if DEBUG || SIMLEASE_TESTING
        let xcrunURL: URL
        if let path = environment["SIMLEASE_XCRUN_PATH"] {
            xcrunURL = URL(fileURLWithPath: path)
        } else {
            xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
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
        let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
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
                )
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
            storageProvider: storageProvider
        )
    }

    private static func runStatus(
        json: Bool,
        audit: Bool,
        devices: Bool,
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let coordinator = try makeCoordinator(configuration: configuration)
        var status = try coordinator.status()
        let heldLanes = Set((status.lanes ?? []).map(\.owner).map(\.pid))
        let tasks = SimulatorTaskStore.records(base: configuration.paths).filter { heldLanes.contains($0.1.owner.pid) }.map { ($0.0.lane, $0.1) }
        if audit {
            let report = SimulatorActivityAudit().scan(status: status, base: configuration.paths)
            status = LeaseStatus(state: status.state, owner: status.owner, waiters: status.waiters, error: status.error, activity: report, lanes: status.lanes)
        }
        let blocks = try CrashLoopStore(paths: configuration.paths).read().blocks.values.sorted { $0.deviceID < $1.deviceID }
        var usage: [SimulatorUsage]?
        var stale: [StaleRuntime]?
        if devices {
            let xcrun: URL
            #if DEBUG || SIMLEASE_TESTING
            xcrun = URL(fileURLWithPath: environment["SIMLEASE_XCRUN_PATH"] ?? "/usr/bin/xcrun")
            #else
            xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
            #endif
            let manager = configuration.deviceManager ?? ProcessSimulatorDeviceManager(environment: environment, xcrunURL: xcrun)
            let relevant = status.waiters.flatMap { $0.deviceIDs ?? [] } + (status.activity?.activities.flatMap(\.deviceIDs) ?? []) + blocks.map(\.deviceID)
            stale = configuration.deviceManager == nil ? RuntimeCompatibility.cached(paths: configuration.paths, environment: environment, xcrunURL: xcrun) : []
            usage = (try? manager.inventory()).map {
                SimulatorUsage.build(inventory: $0, tasks: tasks, relevantIDs: Set(relevant), warm: (try? WarmDeviceStore(paths: configuration.paths).read()) ?? [:], staleRuntimes: Set((stale ?? []).map(\.identifier)))
            }
        }
        let laneLimit = LaneConfig.read(configuration.paths).maxLanes
        let gateStatus = laneLimit > 1 && devices ? HeadroomGate(paths: configuration.paths).check() : nil
        let history = LaneHistoryStore(paths: configuration.paths)
        let projects = Set(status.waiters.map(\.project) + (status.owner.map { [$0.project] } ?? []))
        let durations = history.typicalDurations(projects: projects)
        var nativeIdleSince: Date?
        if status.state == .leased, let owner = status.owner, let task = tasks.first(where: { $0.0 == 0 })?.1, task.owner.pid == owner.pid, task.phase == .running, let sessionID = task.externalSessionID {
            nativeIdleSince = max(owner.acquiredAt, history.lastNativeActivity(sessionID: sessionID) ?? owner.acquiredAt)
        }
        status = LeaseStatus(state: status.state, owner: status.owner, waiters: status.waiters, error: status.error, activity: status.activity, crashBlocks: blocks, devices: usage, typicalDurations: durations.isEmpty ? nil : durations, nativeIdleSince: nativeIdleSince, staleRuntimes: stale?.isEmpty == false ? stale : nil, lanes: status.lanes, laneLimit: laneLimit, gate: gateStatus)
        if json {
            let data = try JSONEncoder.simLease.encode(status)
            configuration.standardOutput(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            configuration.standardOutput("\(status.state.rawValue)\n")
            for device in usage ?? [] { configuration.standardOutput("\(device.reservation.rawValue): \(device.name) \(device.id) \(device.state)\n") }
            for runtime in stale ?? [] { configuration.standardOutput("Stale runtime: iOS \(runtime.version) \(runtime.build) is older than the Xcode SDK \(runtime.sdkBuild)\n") }
            for block in blocks { configuration.standardOutput("Crash blocked: \(block.processName) on \(block.deviceID)\n") }
            if let activity = status.activity {
                for item in activity.activities { configuration.standardOutput("\(item.kind.rawValue): \(item.tool) PID \(item.process.pid)\n") }
                if activity.isIncomplete { configuration.standardOutput("Activity audit incomplete\n") }
            }
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
        deviceIDs: [String],
        keepRunning: Bool,
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let identity = LeaseIdentity(
            pid: getpid(), cwd: FileManager.default.currentDirectoryPath,
            project: project, command: arguments, source: .manualXcode,
            threadID: environment["CODEX_THREAD_ID"], threadTitle: title
        )
        configuration.standardOutput("SimLease: reserving for \(title) (\(project)); press Ctrl-C to release\n")
        return try taskService(environment: environment, configuration: configuration).run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do /bin/sleep 3600; done"],
            deviceIDs: deviceIDs, keepRunning: keepRunning, laneZeroOnly: true, environment: environment, identity: identity
        )
    }

    private static func taskService(
        environment: [String: String], configuration: CLIConfiguration
    ) -> SimulatorTaskService {
        let xcrun: URL
        #if DEBUG || SIMLEASE_TESTING
        xcrun = URL(fileURLWithPath: environment["SIMLEASE_XCRUN_PATH"] ?? "/usr/bin/xcrun")
        #else
        xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        #endif
        return SimulatorTaskService(
            paths: configuration.paths,
            devices: SimulatorDeviceController(environment: environment, xcrunURL: xcrun),
            timing: configuration.timing, report: configuration.standardError,
            crashReportDirectory: configuration.crashReportDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
            warmPolicy: try? warmPolicy(environment: environment, configuration: configuration)
        )
    }

    private static func shutdownService(title: String, arguments: [String], environment: [String: String], configuration: CLIConfiguration) throws -> SimulatorShutdownService {
        let xcrun: URL
        #if DEBUG || SIMLEASE_TESTING
        xcrun = URL(fileURLWithPath: environment["SIMLEASE_XCRUN_PATH"] ?? "/usr/bin/xcrun")
        #else
        xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        #endif
        let threadID = environment["CODEX_THREAD_ID"]
        let identity = LeaseIdentity(pid: getpid(), cwd: FileManager.default.currentDirectoryPath, project: "SimLease", command: arguments, source: threadID == nil ? .terminal : .codex, threadID: threadID, threadTitle: title)
        return SimulatorShutdownService(paths: configuration.paths, coordinator: try makeCoordinator(configuration: configuration), identity: identity, devices: configuration.deviceManager ?? ProcessSimulatorDeviceManager(environment: environment, xcrunURL: xcrun))
    }

    private static func warmPolicy(environment: [String: String], configuration: CLIConfiguration) throws -> ProcessWarmDevicePolicy {
        let xcrun: URL
        #if DEBUG || SIMLEASE_TESTING
        xcrun = URL(fileURLWithPath: environment["SIMLEASE_XCRUN_PATH"] ?? "/usr/bin/xcrun")
        #else
        xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        #endif
        let manager = ProcessSimulatorDeviceManager(environment: environment, xcrunURL: xcrun)
        return ProcessWarmDevicePolicy(paths: configuration.paths, manager: manager, shutdownService: try shutdownService(title: "Reap warm simulators", arguments: [], environment: environment, configuration: configuration))
    }

    private static func deviceService(arguments: [String], environment: [String: String], configuration: CLIConfiguration) throws -> DeviceRepairService {
        if insideManagedWork(configuration) {
            throw SimulatorTaskError.commandFailed("device recovery cannot nest inside a managed job or native session; finish and settle it first")
        }
        let store = try MetadataStore(paths: configuration.paths)
        let identity = try LeaseIdentity.resolve(environment: environment, cwd: FileManager.default.currentDirectoryPath, command: arguments, store: store)
        let xcrun: URL
        #if DEBUG || SIMLEASE_TESTING
        xcrun = URL(fileURLWithPath: environment["SIMLEASE_XCRUN_PATH"] ?? "/usr/bin/xcrun")
        #else
        xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        #endif
        return DeviceRepairService(paths: configuration.paths, coordinator: try makeCoordinator(configuration: configuration), identity: identity, devices: configuration.deviceManager ?? ProcessSimulatorDeviceManager(environment: environment, xcrunURL: xcrun))
    }

    private static func runTask(
        command: [String], deviceIDs: [String], keepRunning: Bool, keepWarm: Bool,
        environment: [String: String], configuration: CLIConfiguration
    ) throws -> Int32 {
        guard let name = command.first else { throw CommandParserError.usage }
        let executable: URL
        if name.contains("/") {
            executable = URL(fileURLWithPath: name).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ExecutableResolutionError.notFound(name)
            }
        } else {
            executable = try ExecutableResolver.resolve(
                name: name, path: environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
                excluding: URL(fileURLWithPath: "/dev/null")
            )
        }
        let store = try MetadataStore(paths: configuration.paths)
        let ids = deviceIDs + SimulatorCommand.referencedDeviceIDs(in: command)
        let arguments = SimulatorCommand.argumentsForManagedTask(executable: executable.path, arguments: Array(command.dropFirst()), hasDevices: !ids.isEmpty)
        let childEnvironment = ManagedToolEnvironment.make(executable: executable, arguments: arguments, environment: environment)
        if let lane = try SimulatorTaskStore.authorizedLane(base: configuration.paths, environment: environment, pid: getpid()) {
            guard !keepWarm else { throw SimulatorTaskError.commandFailed("declare --keep-warm on the outer run only") }
            let laneStore = SimulatorTaskStore(paths: lane)
            try laneStore.validateNestedDevices(ids)
            try requireScopedTarget([executable.path] + arguments, record: laneStore.read(), configuration: configuration)
            if !CrashLoopStore.permitsCleanup([executable.path] + arguments) {
                let declared = try laneStore.read()?.deviceIDs ?? []
                try CrashLoopStore(paths: configuration.paths).requireHealthy(ids.isEmpty ? declared : ids)
            }
            if try prepareWarmCommand(invocation: [executable.path] + arguments, record: laneStore.read(), environment: environment, configuration: configuration) { return 0 }
            return try ChildProcessRunner.run(executable: executable, arguments: arguments, environment: childEnvironment).exitCode
        }
        let identity = try LeaseIdentity.resolve(environment: environment, cwd: FileManager.default.currentDirectoryPath, command: command, store: store)
        warnAboutStaleRuntimes(ids, environment: environment, configuration: configuration)
        return try taskService(environment: environment, configuration: configuration).run(
            executable: executable, arguments: arguments, deviceIDs: ids,
            keepRunning: keepRunning, keepWarm: keepWarm, environment: childEnvironment, identity: identity
        )
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

        let authorizedLane = try SimulatorTaskStore.authorizedLane(base: configuration.paths, environment: environment, pid: getpid())
        let nested = authorizedLane != nil
        let journal = SimulatorTaskStore(paths: authorizedLane ?? configuration.paths)
        let native = !nested && (decision.requiresLease || SimulatorCommand.isXcodebuild(executable: invokedPath, arguments: childArguments))
            ? try NativeClientAdmission.acquire(paths: configuration.paths, invocation: invocation, pid: getpid()) : nil
        defer { withExtendedLifetime(native) {} }
        let admittedTask = nested || native != nil ? try journal.read() : nil
        let taskDevices = admittedTask?.deviceIDs ?? []
        let ids = SimulatorCommand.referencedDeviceIDs(in: invocation)
        if nested {
            try journal.validateNestedDevices(SimulatorCommand.referencedDeviceIDs(in: invocation))
            if decision.requiresLease { try requireScopedTarget(invocation, record: admittedTask, configuration: configuration) }
            if decision.requiresLease, !CrashLoopStore.permitsCleanup(invocation) {
                try CrashLoopStore(paths: configuration.paths).requireHealthy(ids.isEmpty ? taskDevices : ids)
            }
        }
        if nested || native != nil,
           try prepareWarmCommand(invocation: invocation, record: admittedTask, environment: environment, configuration: configuration) { return 0 }
        let arguments = SimulatorCommand.argumentsForManagedTask(executable: executable.path, arguments: childArguments, hasDevices: !ids.isEmpty || !taskDevices.isEmpty)
        let childEnvironment = ManagedToolEnvironment.make(
            executable: executable, arguments: arguments, environment: environment,
            shimDirectory: invokedURL.deletingLastPathComponent(), stripShims: native != nil
        )
        guard decision.requiresLease, !nested, native == nil else {
            return try ChildProcessRunner.run(executable: executable, arguments: arguments, environment: childEnvironment).exitCode
        }
        let store = try MetadataStore(paths: configuration.paths)
        let identity = try LeaseIdentity.resolve(
            environment: environment, cwd: FileManager.default.currentDirectoryPath,
            command: invocation, store: store
        )
        warnAboutStaleRuntimes(ids, environment: environment, configuration: configuration)
        return try taskService(environment: environment, configuration: configuration).run(
            executable: executable, arguments: arguments, deviceIDs: ids,
            keepRunning: false, environment: childEnvironment, identity: identity
        )
    }

    private static func insideManagedWork(_ configuration: CLIConfiguration) -> Bool {
        SimulatorTaskStore.records(base: configuration.paths).contains { _, record in
            record.owner.isAncestor(of: getpid()) || record.nativeClients?.contains(where: { $0.isAncestor(of: getpid()) }) == true
        }
    }

    private static func requireScopedTarget(_ invocation: [String], record: SimulatorTaskRecord?, configuration: CLIConfiguration) throws {
        guard record?.exclusive != true, LaneConfig.read(configuration.paths).maxLanes > 1,
              ProtectedCommand.classify(invocation: invocation).requiresLease,
              SimulatorCommand.referencedDeviceIDs(in: invocation).isEmpty
        else { return }
        throw SimulatorTaskError.commandFailed("several simulator lanes are enabled; name the simulator UUID in nested commands, for example -destination id=UUID")
    }

    private static func prepareWarmCommand(invocation: [String], record: SimulatorTaskRecord?, environment: [String: String], configuration: CLIConfiguration) throws -> Bool {
        let claimed = Set(record?.warmClaimedDeviceIDs ?? [])
        guard !claimed.isEmpty else { return false }
        let xcrun: URL
        #if DEBUG || SIMLEASE_TESTING
        xcrun = URL(fileURLWithPath: environment["SIMLEASE_XCRUN_PATH"] ?? "/usr/bin/xcrun")
        #else
        xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        #endif
        let controller = SimulatorDeviceController(environment: environment, xcrunURL: xcrun)
        let boot = SimulatorCommand.bootTarget(in: invocation)
        if let id = boot, claimed.contains(id), try controller.states()[id] == "Booted" {
            configuration.standardError("SimLease: \(id) is already booted\n")
            return true
        }
        for id in SimulatorCommand.shutdownRequiredTargets(in: invocation) where claimed.contains(id) && boot == nil {
            try controller.shutdown(id)
        }
        return false
    }

    private static func warnAboutStaleRuntimes(_ ids: [String], environment: [String: String], configuration: CLIConfiguration) {
        guard !ids.isEmpty, configuration.deviceManager == nil else { return }
        let xcrun: URL
        #if DEBUG || SIMLEASE_TESTING
        xcrun = URL(fileURLWithPath: environment["SIMLEASE_XCRUN_PATH"] ?? "/usr/bin/xcrun")
        #else
        xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        #endif
        let stale = RuntimeCompatibility.cached(paths: configuration.paths, environment: environment, xcrunURL: xcrun)
        guard !stale.isEmpty, let inventory = try? ProcessSimulatorDeviceManager(environment: environment, xcrunURL: xcrun).inventory() else { return }
        let wanted = Set(ids.map { $0.uppercased() })
        for device in inventory where wanted.contains(device.id) {
            guard let runtime = stale.first(where: { $0.identifier == device.runtime }) else { continue }
            configuration.standardError("SimLease: warning: \(device.name) \(device.id) runs iOS \(runtime.version) \(runtime.build), older than the Xcode SDK \(runtime.sdkBuild). Apps built with this Xcode can crash calling missing system symbols. Install the matching runtime with xcodebuild -downloadPlatform iOS.\n")
        }
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
        case .nativeTool: "Native tool"
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

private struct NativeSessionReady: Encodable {
    let state = "ready"
    let sessionID: String
    let pid: Int32
    let deviceIDs: [String]
    let ownedDeviceIDs: [String]
}

private struct ReapOutput: Encodable {
    let busy: Bool
    let results: [SimulatorShutdownResult]
}

private struct ConfigOutput: Encodable {
    let maxLanes: Int
    let gate: LaneGateStatus?
}
