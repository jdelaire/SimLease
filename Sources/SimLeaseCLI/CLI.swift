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

    public init(
        paths: LeasePaths,
        timing: LeaseTiming,
        standardOutput: @escaping @Sendable (String) -> Void,
        standardError: @escaping @Sendable (String) -> Void,
        cleanupService: (any CleanupServicing)? = nil,
        updateRunner: (any UpdateRunning)? = nil
    ) {
        self.paths = paths
        self.timing = timing
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.cleanupService = cleanupService
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
            case .run(let ids, let keepRunning, let command):
                return try runTask(command: command, deviceIDs: ids, keepRunning: keepRunning, environment: environment, configuration: configuration)
            case .recover:
                let store = try MetadataStore(paths: configuration.paths)
                let identity = try LeaseIdentity.resolve(environment: environment, cwd: FileManager.default.currentDirectoryPath, command: arguments, store: store)
                try taskService(environment: environment, configuration: configuration).recover(identity: identity)
                configuration.standardOutput("SimLease: recovery complete\n")
                return 0
            case .status(let json):
                return try runStatus(json: json, configuration: configuration)
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
                "Usage: simlease <run|recover|doctor|status|name|hold|clean|update|--version>\n"
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
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let coordinator = try makeCoordinator(configuration: configuration)
        var status = try coordinator.status()
        if status.state == .free, let record = try SimulatorTaskStore(paths: configuration.paths).read() {
            status = LeaseStatus(state: .metadataError, owner: nil, waiters: status.waiters, error: "unfinished task \(record.token): \(record.failure ?? record.phase.rawValue); run simlease recover")
        }
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
            deviceIDs: deviceIDs, keepRunning: keepRunning, environment: environment, identity: identity
        )
    }

    private static func taskService(
        environment: [String: String], configuration: CLIConfiguration
    ) -> SimulatorTaskService {
        SimulatorTaskService(
            paths: configuration.paths,
            devices: SimulatorDeviceController(environment: environment),
            timing: configuration.timing, report: configuration.standardError
        )
    }

    private static func runTask(
        command: [String], deviceIDs: [String], keepRunning: Bool,
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
        if try SimulatorTaskStore(paths: configuration.paths).authorizesNestedCommand(environment: environment, pid: getpid()) {
            try SimulatorTaskStore(paths: configuration.paths).validateNestedDevices(ids)
            return try ChildProcessRunner.run(executable: executable, arguments: arguments, environment: childEnvironment).exitCode
        }
        let identity = try LeaseIdentity.resolve(environment: environment, cwd: FileManager.default.currentDirectoryPath, command: command, store: store)
        return try taskService(environment: environment, configuration: configuration).run(
            executable: executable, arguments: arguments, deviceIDs: ids,
            keepRunning: keepRunning, environment: childEnvironment, identity: identity
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

        let journal = SimulatorTaskStore(paths: configuration.paths)
        let nested = try journal.authorizesNestedCommand(environment: environment, pid: getpid())
        let taskDevices = nested ? (try journal.read()?.deviceIDs ?? []) : []
        let ids = SimulatorCommand.referencedDeviceIDs(in: invocation)
        if nested { try journal.validateNestedDevices(SimulatorCommand.referencedDeviceIDs(in: invocation)) }
        let arguments = SimulatorCommand.argumentsForManagedTask(executable: executable.path, arguments: childArguments, hasDevices: !ids.isEmpty || !taskDevices.isEmpty)
        let childEnvironment = ManagedToolEnvironment.make(
            executable: executable, arguments: arguments, environment: environment,
            shimDirectory: invokedURL.deletingLastPathComponent()
        )
        guard decision.requiresLease, !nested else {
            return try ChildProcessRunner.run(executable: executable, arguments: arguments, environment: childEnvironment).exitCode
        }
        let store = try MetadataStore(paths: configuration.paths)
        let identity = try LeaseIdentity.resolve(
            environment: environment, cwd: FileManager.default.currentDirectoryPath,
            command: invocation, store: store
        )
        return try taskService(environment: environment, configuration: configuration).run(
            executable: executable, arguments: arguments, deviceIDs: ids,
            keepRunning: false, environment: childEnvironment, identity: identity
        )
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
