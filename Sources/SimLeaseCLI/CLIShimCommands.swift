import Darwin
import Dispatch
import Foundation
import SimLeaseCore

extension SimLeaseCLI {
    static func runShim(
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

        // One latch spans acquisition, lane setup, and child execution so
        // SIGTERM is observed rather than killing us with the lease held.
        let signals = SignalLatch()

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
                configuration: configuration,
                signals: signals
            )
            var laneHandle: LaneLockHandle?
            defer { laneHandle?.release() }
            do {
                let freshDescriptor = try laneStore.readDescriptor(at: descriptorURL)
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
            return try runProtectedChild(
                executable: executable,
                arguments: childArguments,
                environment: environment
            )
        case .global:
            let global = try acquireGlobalLease(
                coordinator: coordinator,
                identity: identity,
                configuration: configuration,
                signals: signals
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
        configuration: CLIConfiguration,
        signals: SignalLatch
    ) throws -> LeaseHandle {
        try coordinator.acquire(
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
}

final class SignalLatch: @unchecked Sendable {
    private static let dispositionLock = NSLock()
    private nonisolated(unsafe) static var activeLatches = 0
    private nonisolated(unsafe) static var savedINT: sig_t?
    private nonisolated(unsafe) static var savedTERM: sig_t?
    private nonisolated(unsafe) static var savedHUP: sig_t?

    private let lock = NSLock()
    private var received: Int32?
    private var sources: [DispatchSourceSignal] = []

    init() {
        Self.dispositionLock.lock()
        if Self.activeLatches == 0 {
            Self.savedINT = signal(SIGINT, SIG_IGN)
            Self.savedTERM = signal(SIGTERM, SIG_IGN)
            Self.savedHUP = signal(SIGHUP, SIG_IGN)
        }
        Self.activeLatches += 1
        Self.dispositionLock.unlock()

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
        Self.dispositionLock.lock()
        Self.activeLatches -= 1
        if Self.activeLatches == 0 {
            _ = signal(SIGINT, Self.savedINT)
            _ = signal(SIGTERM, Self.savedTERM)
            _ = signal(SIGHUP, Self.savedHUP)
        }
        Self.dispositionLock.unlock()
    }

    var current: Int32? {
        lock.withLock { received }
    }
}
