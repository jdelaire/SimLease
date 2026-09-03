import Foundation
import SimLeaseCore

extension SimLeaseCLI {
    static func runCleanPlan(
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

    static func runCleanApply(
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

    static func currentLaneProtection(
        paths: LeasePaths
    ) throws -> LaneProtectionSnapshot {
        let laneStore = try LaneStore(paths: paths)
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
        return LaneProtectionSnapshot(
            reservedDeviceIDs: Set(state.reservations.map(\.udid)),
            activeDerivedDataPaths: derivedDataPaths,
            activeResultBundlePaths: state.reservations.isEmpty
                ? []
                : [paths.laneResultBundles.path]
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
                laneProtection = try currentLaneProtection(
                    paths: configuration.paths
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
        let lanePaths = configuration.paths
        let executor = CleanupExecutor(
            provider: provider,
            planner: planner,
            storageProvider: storageProvider,
            fileOperator: fileOperator,
            laneProtectionProvider: {
                try currentLaneProtection(paths: lanePaths)
            }
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
}
