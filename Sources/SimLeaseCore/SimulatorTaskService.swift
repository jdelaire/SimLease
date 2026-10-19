import Foundation

public final class SimulatorTaskService: Sendable {
    private let paths: LeasePaths
    private let devices: any SimulatorDeviceControlling
    private let timing: LeaseTiming
    private let report: @Sendable (String) -> Void
    private let crashReportDirectory: URL
    private let warmPolicy: (any WarmDevicePolicy)?

    public init(
        paths: LeasePaths, devices: any SimulatorDeviceControlling,
        timing: LeaseTiming = .production,
        report: @escaping @Sendable (String) -> Void = { _ in },
        crashReportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
        warmPolicy: (any WarmDevicePolicy)? = nil
    ) {
        self.warmPolicy = warmPolicy
        self.paths = paths
        self.devices = devices
        self.timing = timing
        self.report = report
        self.crashReportDirectory = crashReportDirectory
    }

    public func run(
        executable: URL, arguments: [String], deviceIDs: [String], keepRunning: Bool, keepWarm: Bool = false,
        environment: [String: String], identity: LeaseIdentity,
        externalSessionID: String? = nil,
        nativeClients: [ProcessReference] = [],
        onStarted: (SimulatorTaskRecord) throws -> Void = { _ in }
    ) throws -> Int32 {
        guard !keepWarm || !keepRunning else {
            throw SimulatorTaskError.commandFailed("--keep-warm and --keep-running cannot be combined")
        }
        if let externalSessionID, UUID(uuidString: externalSessionID) == nil {
            throw SimulatorTaskError.commandFailed("invalid native session identity")
        }
        let signals = TaskSignals()
        let metadata = try MetadataStore(paths: paths)
        let coordinator = LeaseCoordinator(paths: paths, store: metadata, timing: timing)
        let ids = Array(Set(deviceIDs.map { $0.uppercased() })).sorted()
        let handle = try coordinator.acquire(
            identity: identity,
            onWaitReport: { [report] in report("SimLease: waiting for \($0.owner?.project ?? "simulator owner")\n") },
            cancellationSignal: { signals.current },
            allowUnfinishedTask: true,
            deviceIDs: ids
        )
        defer { handle.release() }
        try recoverPending()
        if let number = signals.current { return 128 + number }
        guard nativeClients.isEmpty || externalSessionID != nil else {
            throw SimulatorTaskError.commandFailed("native clients require a native session")
        }
        for client in nativeClients where client.state != .matching {
            throw SimulatorTaskError.unverifiedProcess(client.pid)
        }
        let crashes = CrashLoopStore(paths: paths)
        let source = CrashReportSource(directory: crashReportDirectory)
        _ = try crashes.ingest(source.scan(), now: Date())
        if !CrashLoopStore.permitsCleanup([executable.path] + arguments) { try crashes.requireHealthy(ids) }
        let warmStore = WarmDeviceStore(paths: paths)
        if let warmPolicy, try !warmStore.read().isEmpty { try warmPolicy.reap(excluding: Set(ids)) }
        let warm = warmPolicy == nil ? [:] : try warmStore.read()
        let states = ids.isEmpty ? [:] : try devices.states()
        for id in ids where states[id] == nil { throw SimulatorTaskError.unknownDevice(id) }
        let claimed = ids.filter { warm[$0] != nil && states[$0] == "Booted" }
        var record = SimulatorTaskRecord(
            token: UUID().uuidString, owner: try ProcessReference.current(), deviceIDs: ids,
            ownedDeviceIDs: keepRunning ? [] : ids.filter { states[$0] == "Shutdown" || claimed.contains($0) }
        )
        record.warmClaimedDeviceIDs = keepRunning || claimed.isEmpty ? nil : claimed
        record.externalSessionID = externalSessionID
        record.externalWorkSettled = externalSessionID == nil ? nil : false
        record.nativeClients = nativeClients.isEmpty ? nil : nativeClients
        let crashScopeID = UUID().uuidString
        record.crashScopeID = crashScopeID
        let store = SimulatorTaskStore(paths: paths)
        try store.write(record)
        try warmStore.remove(ids.filter { warm[$0] != nil })
        let needsShutdown = Set(SimulatorCommand.shutdownRequiredTargets(in: [executable.path] + arguments))
        for id in record.warmClaimedDeviceIDs ?? [] where needsShutdown.contains(id) { try devices.shutdown(id) }
        var childEnvironment = environment
        childEnvironment["SIMLEASE_HELD"] = "1"
        childEnvironment["SIMLEASE_TOKEN"] = record.token
        var code: Int32 = 74
        var jobError: Error?
        var stoppedForCrash = false
        var processCleanupFailed = false
        var lastScan: TimeInterval = 0
        var monitoringErrorReported = false
        do {
            code = try TaskProcessRunner.run(
                executable: executable, arguments: arguments, environment: childEnvironment,
                signals: signals,
                onStart: { child in
                    for client in nativeClients where client.state != .matching {
                        throw SimulatorTaskError.unverifiedProcess(client.pid)
                    }
                    record.child = child
                    record.phase = .running
                    try store.write(record)
                    try crashes.beginScope(id: crashScopeID, deviceIDs: record.ownedDeviceIDs, startedAt: Date())
                    try onStarted(record)
                },
                onExit: { _, code in
                    record.exitCode = code
                    record.phase = .cleaning
                    try store.write(record)
                },
                onPoll: {
                    let uptime = ProcessInfo.processInfo.systemUptime
                    guard uptime - lastScan >= 1 else { return }
                    lastScan = uptime
                    do {
                        for trigger in try crashes.ingest(source.scan(), now: Date()) {
                            report("SimLease: repeated \(trigger.processName) crashes blocked \(trigger.deviceID)\n")
                        }
                        if !stoppedForCrash, externalSessionID == nil, try crashes.read().blocks.values.contains(where: { $0.scopeID == crashScopeID }) {
                            stoppedForCrash = true
                            signals.cancel()
                        }
                    } catch {
                        if !monitoringErrorReported {
                            report("SimLease: crash inspection unavailable; \(error)\n")
                            monitoringErrorReported = true
                        }
                    }
                }
            )
        } catch let error as TaskProcessCleanupError {
            processCleanupFailed = true
            code = error.exitCode
            report("SimLease: retrying process cleanup: \(error.detail)\n")
        } catch {
            jobError = error
        }
        if stoppedForCrash { code = 70 }
        var warmable = keepWarm && warmPolicy != nil && externalSessionID == nil && code == 0 && jobError == nil && !processCleanupFailed && !monitoringErrorReported && !stoppedForCrash && signals.current == nil
        if warmable {
            do { _ = try crashes.ingest(source.scan(), now: Date()) }
            catch {
                warmable = false
                report("SimLease: crash inspection unavailable; shutting down owned devices: \(error)\n")
            }
        }
        var finished = false
        var cancellationAtCommit: Int32?
        do {
            cancellationAtCommit = try finish(&record, warm: warmable, cancellationSignal: { signals.current })
            finished = true
        } catch {
            report("SimLease: cleanup failed; lane quarantined: \(error)\n")
            if code == 0 { code = 74 }
        }
        if warmable, finished {
            do { try warmPolicy?.reap(excluding: []) }
            catch { report("SimLease: warm simulator reaping failed: \(error)\n") }
        }
        try? LaneHistoryStore(paths: paths).record(project: identity.project, startedAt: handle.owner.acquiredAt, endedAt: Date())
        if let jobError { throw jobError }
        if code == 0, let number = cancellationAtCommit { return 128 + number }
        return code
    }

    public func recover(identity: LeaseIdentity) throws {
        let metadata = try MetadataStore(paths: paths)
        let coordinator = LeaseCoordinator(paths: paths, store: metadata, timing: timing)
        guard let handle = try coordinator.tryAcquire(identity: identity, allowUnfinishedTask: true) else {
            throw SimulatorTaskError.unfinishedTask("another job holds the lane")
        }
        defer { handle.release() }
        try recoverPending()
    }

    private func recoverPending() throws {
        let store = SimulatorTaskStore(paths: paths)
        guard var record = try store.read() else { return }
        if record.phase != .quarantined {
            switch record.owner.state {
            case .missing, .reused: break
            case .matching, .unknown:
                throw SimulatorTaskError.unfinishedTask("owner \(record.owner.pid) is live or unverifiable")
            }
        }
        report("SimLease: recovering unfinished task \(record.token)\n")
        try finish(&record)
    }

    @discardableResult
    private func finish(_ record: inout SimulatorTaskRecord, warm: Bool = false, cancellationSignal: () -> Int32? = { nil }) throws -> Int32? {
        let store = SimulatorTaskStore(paths: paths)
        record.phase = .cleaning
        try store.write(record)
        do {
            if record.externalSessionID != nil {
                let settlements = NativeSettlementStore(paths: paths)
                guard try record.externalWorkSettled == true || settlements.isAcknowledged(record) else {
                    throw SimulatorTaskError.commandFailed("native work is unresolved; confirm settlement with simlease session finish \(record.externalSessionID!) --settled")
                }
                record.externalWorkSettled = true
                try store.write(record)
            }
            if let child = record.child { try TaskProcessRunner.stopGroup(child) }
            var warmed = [String]()
            for id in record.ownedDeviceIDs {
                guard let current = try devices.states()[id] else { continue }
                if warm, cancellationSignal() == nil, current == "Booted", let warmPolicy, (try? warmPolicy.canWarm(id)) == true, (try? warmPolicy.terminateApps(id)) != nil, cancellationSignal() == nil {
                    warmed.append(id)
                    continue
                }
                try devices.shutdown(id)
                let state = try devices.states()[id]
                guard state == nil || state == "Shutdown" else {
                    throw SimulatorTaskError.commandFailed("shutdown was not verified for \(id)")
                }
            }
            if cancellationSignal() != nil {
                for id in warmed { try shutdownAndVerify(id) }
                warmed.removeAll()
            }
            if record.externalSessionID != nil { try NativeSettlementStore(paths: paths).remove(record) }
            if let scopeID = record.crashScopeID { try CrashLoopStore(paths: paths).endScope(id: scopeID, endedAt: Date()) }
            let warmStore = WarmDeviceStore(paths: paths)
            try warmStore.remove(record.deviceIDs)
            if !warmed.isEmpty { try warmStore.add(warmed, since: Date()) }
            let cancellation = cancellationSignal()
            if cancellation != nil {
                for id in warmed { try shutdownAndVerify(id) }
                try warmStore.remove(warmed)
            }
            try store.remove()
            return cancellation
        } catch {
            record.phase = .quarantined
            record.failure = String(describing: error)
            try store.write(record)
            throw SimulatorTaskError.unfinishedTask(String(describing: error))
        }
    }

    private func shutdownAndVerify(_ id: String) throws {
        try devices.shutdown(id)
        let state = try devices.states()[id]
        guard state == nil || state == "Shutdown" else {
            throw SimulatorTaskError.commandFailed("shutdown was not verified for \(id)")
        }
    }
}
