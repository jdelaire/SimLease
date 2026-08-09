import Darwin
import Foundation

public protocol LaneServicing: Sendable {
    func acquire(
        request: LaneAcquireRequest,
        identity: LeaseIdentity
    ) throws -> LaneAcquireResult
    func status(now: Date) throws -> LaneStatusReport
    func configure(maxActive: Int?) throws -> LaneConfigurationReport
    func renew(descriptorURL: URL, now: Date) throws -> LaneDescriptor
    func release(
        descriptorURL: URL,
        identity: LeaseIdentity
    ) throws -> LaneReleaseResult
    func createRecoveryPlan(laneID: String, now: Date) throws -> LaneLifecyclePlan
    func applyRecovery(
        planID: String,
        laneID: String,
        now: Date
    ) throws -> LaneReleaseResult
    func createDisposalPlan(udid: String, now: Date) throws -> LaneLifecyclePlan
    func applyDisposal(
        planID: String,
        udid: String,
        now: Date
    ) throws -> LaneDisposalResult
}

public final class LaneService: LaneServicing, @unchecked Sendable {
    private let paths: LeasePaths
    private let store: any LaneStoring
    private let provider: any LaneSimulatorProviding
    private let coordinator: LeaseCoordinator
    private let laneLocks: LaneLockCoordinator
    private let planStore: any LanePlanStoring
    private let now: () -> Date
    private let tokenGenerator: () -> String
    private let planIDGenerator: () -> String

    public init(
        paths: LeasePaths,
        store: any LaneStoring,
        provider: any LaneSimulatorProviding,
        coordinator: LeaseCoordinator,
        laneLocks: LaneLockCoordinator,
        planStore: any LanePlanStoring,
        now: @escaping () -> Date = Date.init,
        tokenGenerator: @escaping () -> String = { UUID().uuidString },
        planIDGenerator: @escaping () -> String = {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        }
    ) {
        self.paths = paths
        self.store = store
        self.provider = provider
        self.coordinator = coordinator
        self.laneLocks = laneLocks
        self.planStore = planStore
        self.now = now
        self.tokenGenerator = tokenGenerator
        self.planIDGenerator = planIDGenerator
    }

    public func acquire(
        request: LaneAcquireRequest,
        identity: LeaseIdentity
    ) throws -> LaneAcquireResult {
        let global = try coordinator.acquire(identity: identity)
        defer { global.release() }

        var state = try store.readState()
        guard state.reservations.count < state.configuration.maxActive else {
            throw LaneServiceError.capacityFull(try makeStatus(state: state, now: now()))
        }
        let occupied = Set(state.reservations.map(\.slot))
        guard let slot = (1...state.configuration.maxActive).first(where: {
            !occupied.contains($0)
        }) else {
            throw LaneServiceError.capacityFull(try makeStatus(state: state, now: now()))
        }

        let allSlots = try laneLocks.acquireAll(maxSlot: state.configuration.maxActive)
        defer { allSlots.release() }
        state = try store.readState()
        guard state.reservations.count < state.configuration.maxActive,
              !state.reservations.contains(where: { $0.slot == slot })
        else {
            throw LaneServiceError.capacityFull(try makeStatus(state: state, now: now()))
        }

        var inventory = try provider.inventory()
        let runtime = try inventory.resolveRuntime(request.runtime)
        let deviceType = try inventory.resolveDeviceType(request.deviceType)
        let acquiredAt = now()
        let laneID = "lane-\(slot)"
        let token = tokenGenerator()
        let safeProject = Self.safePathComponent(request.project)
        let derivedData = paths.laneDerivedData
            .appendingPathComponent(safeProject, isDirectory: true)
            .appendingPathComponent(laneID, isDirectory: true)
        let resultBundle = paths.laneResultBundles
            .appendingPathComponent(safeProject, isDirectory: true)
            .appendingPathComponent(
                "\(laneID)-\(token).xcresult",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: derivedData,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: resultBundle.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var managedIndex: Int?
        var selectedDevice: LaneSimulatorDevice?
        for index in state.managedDevices.indices {
            let record = state.managedDevices[index]
            guard record.lifecycle == .idle,
                  record.deviceTypeIdentifier == deviceType.identifier,
                  record.runtimeIdentifier == runtime.identifier,
                  let device = inventory.devices.first(where: { $0.udid == record.udid }),
                  device.state.caseInsensitiveCompare("Shutdown") == .orderedSame,
                  device.deviceTypeIdentifier == record.deviceTypeIdentifier,
                  device.runtimeIdentifier == record.runtimeIdentifier,
                  device.dataPath.map({
                      URL(fileURLWithPath: $0).standardizedFileURL.path
                  }) == URL(fileURLWithPath: record.expectedDataPath).standardizedFileURL.path
            else { continue }
            managedIndex = index
            selectedDevice = device
            break
        }

        if selectedDevice == nil {
            let name = "[SimLease] \(request.project) \(slot)"
            let udid = try provider.createDevice(
                name: name,
                deviceTypeID: deviceType.identifier,
                runtimeID: runtime.identifier
            )
            inventory = try provider.inventory()
            guard let created = inventory.devices.first(where: { $0.udid == udid }),
                  let dataPath = created.dataPath,
                  created.deviceTypeIdentifier == deviceType.identifier,
                  created.runtimeIdentifier == runtime.identifier
            else {
                throw LaneServiceError.metadataError(
                    "created simulator identity missing from fresh inventory"
                )
            }
            selectedDevice = created
            state.managedDevices.append(ManagedSimulatorRecord(
                udid: udid,
                name: name,
                deviceTypeIdentifier: deviceType.identifier,
                deviceTypeName: deviceType.name,
                runtimeIdentifier: runtime.identifier,
                runtimeName: runtime.name,
                expectedDataPath: dataPath,
                createdAt: acquiredAt,
                lifecycle: .idle
            ))
            managedIndex = state.managedDevices.indices.last
        }
        guard let device = selectedDevice, let managedIndex else {
            throw LaneServiceError.metadataError("unable to select managed simulator")
        }
        state.managedDevices[managedIndex].lifecycle = .reserved

        let expiresAt = acquiredAt.addingTimeInterval(2 * 60 * 60)
        let descriptor = LaneDescriptor(
            laneID: laneID,
            slot: slot,
            token: token,
            project: request.project,
            threadID: identity.threadID,
            threadTitle: identity.threadTitle,
            udid: device.udid,
            deviceTypeIdentifier: deviceType.identifier,
            deviceTypeName: deviceType.name,
            runtimeIdentifier: runtime.identifier,
            runtimeName: runtime.name,
            derivedDataPath: derivedData.path,
            acquiredAt: acquiredAt,
            lastActivityAt: acquiredAt,
            expiresAt: expiresAt
        )
        let descriptorURL = paths.laneDescriptors.appendingPathComponent(
            "\(laneID).json"
        )
        state.reservations.append(LaneReservation(
            laneID: laneID,
            slot: slot,
            token: token,
            project: request.project,
            threadID: identity.threadID,
            threadTitle: identity.threadTitle,
            udid: device.udid,
            descriptorPath: descriptorURL.path,
            generation: 1,
            acquiredAt: acquiredAt,
            lastActivityAt: acquiredAt,
            expiresAt: expiresAt
        ))
        do {
            try store.writeState(state)
            _ = try store.writeDescriptor(descriptor)
        } catch {
            state.reservations.removeAll { $0.laneID == laneID }
            state.managedDevices[managedIndex].lifecycle = .idle
            if device.state.caseInsensitiveCompare("Shutdown") != .orderedSame {
                try? provider.shutdownDevice(udid: device.udid)
            }
            try? store.writeState(state)
            try? store.removeDescriptor(at: descriptorURL)
            throw error
        }

        return LaneAcquireResult(
            state: .acquired,
            lane: descriptor,
            environment: ["SIMLEASE_LANE_FILE": descriptorURL.path],
            xcodebuildArguments: [
                "-destination", "platform=iOS Simulator,id=\(device.udid)",
                "-derivedDataPath", derivedData.path,
            ],
            derivedDataPath: derivedData.path,
            resultBundlePath: resultBundle.path,
            releaseCommand: ["simlease", "lane", "release"],
            nextActions: ["export SIMLEASE_LANE_FILE=\(descriptorURL.path)"]
        )
    }

    public func status(now: Date) throws -> LaneStatusReport {
        try makeStatus(state: store.readState(), now: now)
    }

    public func configure(maxActive: Int?) throws -> LaneConfigurationReport {
        let global = try coordinator.acquire(
            identity: lifecycleIdentity(command: [
                "simlease", "lane", "config",
            ])
        )
        defer { global.release() }
        var state = try store.readState()
        let requestedMaximum = maxActive ?? state.configuration.maxActive
        let allLanes = try laneLocks.acquireAll(maxSlot: max(
            maximumSlot(in: state),
            requestedMaximum
        ))
        defer { allLanes.release() }
        state = try store.readState()
        if let maxActive {
            guard maxActive > 0 else {
                throw LaneServiceError.metadataError("max-active must be positive")
            }
            state.configuration = LaneConfiguration(maxActive: maxActive)
            try store.writeState(state)
        }
        return LaneConfigurationReport(
            schemaVersion: 1,
            configuration: state.configuration,
            reservationCount: state.reservations.count
        )
    }

    public func renew(descriptorURL: URL, now: Date) throws -> LaneDescriptor {
        let descriptor = try store.readDescriptor(at: descriptorURL)
        var state = try store.readState()
        guard let index = state.reservations.firstIndex(where: {
            $0.laneID == descriptor.laneID && $0.token == descriptor.token
        }) else {
            throw LaneServiceError.laneOwnershipMismatch(laneID: descriptor.laneID)
        }
        let expiresAt = now.addingTimeInterval(2 * 60 * 60)
        let old = state.reservations[index]
        state.reservations[index] = LaneReservation(
            laneID: old.laneID,
            slot: old.slot,
            token: old.token,
            project: old.project,
            threadID: old.threadID,
            threadTitle: old.threadTitle,
            udid: old.udid,
            descriptorPath: old.descriptorPath,
            generation: old.generation + 1,
            acquiredAt: old.acquiredAt,
            lastActivityAt: now,
            expiresAt: expiresAt
        )
        let renewed = LaneDescriptor(
            laneID: descriptor.laneID,
            slot: descriptor.slot,
            token: descriptor.token,
            project: descriptor.project,
            threadID: descriptor.threadID,
            threadTitle: descriptor.threadTitle,
            udid: descriptor.udid,
            deviceTypeIdentifier: descriptor.deviceTypeIdentifier,
            deviceTypeName: descriptor.deviceTypeName,
            runtimeIdentifier: descriptor.runtimeIdentifier,
            runtimeName: descriptor.runtimeName,
            derivedDataPath: descriptor.derivedDataPath,
            acquiredAt: descriptor.acquiredAt,
            lastActivityAt: now,
            expiresAt: expiresAt
        )
        try store.writeState(state)
        _ = try store.writeDescriptor(renewed)
        return renewed
    }

    public func release(
        descriptorURL: URL,
        identity: LeaseIdentity
    ) throws -> LaneReleaseResult {
        let descriptor = try store.readDescriptor(at: descriptorURL)
        let global = try coordinator.acquire(identity: identity)
        defer { global.release() }
        let slotHandle = try laneLocks.acquire(slot: descriptor.slot)
        defer { slotHandle.release() }
        var state = try store.readState()
        guard let reservationIndex = state.reservations.firstIndex(where: {
            $0.laneID == descriptor.laneID && $0.token == descriptor.token
                && $0.udid == descriptor.udid
        }) else {
            throw LaneServiceError.laneOwnershipMismatch(laneID: descriptor.laneID)
        }
        guard let managedIndex = state.managedDevices.firstIndex(where: {
            $0.udid == descriptor.udid
        }) else {
            throw LaneServiceError.metadataError("reservation references unmanaged device")
        }
        let inventory = try provider.inventory()
        guard let device = inventory.devices.first(where: { $0.udid == descriptor.udid }),
              device.deviceTypeIdentifier == state.managedDevices[managedIndex].deviceTypeIdentifier,
              device.runtimeIdentifier == state.managedDevices[managedIndex].runtimeIdentifier,
              device.dataPath.map({
                  URL(fileURLWithPath: $0).standardizedFileURL.path
              }) == URL(
                  fileURLWithPath: state.managedDevices[managedIndex].expectedDataPath
              ).standardizedFileURL.path
        else {
            throw LaneServiceError.metadataError("managed simulator fingerprint changed")
        }
        if device.state.caseInsensitiveCompare("Shutdown") != .orderedSame {
            try provider.shutdownDevice(udid: device.udid)
        }
        state.reservations.remove(at: reservationIndex)
        state.managedDevices[managedIndex].lifecycle = .idle
        try store.writeState(state)
        try store.removeDescriptor(at: descriptorURL)
        return LaneReleaseResult(
            schemaVersion: 1,
            laneID: descriptor.laneID,
            udid: descriptor.udid,
            state: "idle",
            disposalPlanCommand: [
                "simlease", "lane", "dispose", "plan", descriptor.udid,
            ]
        )
    }

    public func createRecoveryPlan(
        laneID: String,
        now: Date
    ) throws -> LaneLifecyclePlan {
        let state = try store.readState()
        guard let reservation = state.reservations.first(where: {
            $0.laneID == laneID
        }), let managed = state.managedDevices.first(where: {
            $0.udid == reservation.udid
        }) else {
            throw LaneServiceError.metadataError("unknown managed lane \(laneID)")
        }
        let device = try provider.inventory().devices.first {
            $0.udid == reservation.udid
        }
        let fingerprint = makeFingerprint(device: device, managed: managed)
        let consistent = device.map {
            fingerprintMatchesManaged($0, managed: managed)
        } ?? false
        guard reservation.expiresAt <= now || !consistent else {
            throw LaneServiceError.laneRecoveryTooRecent(
                expiresAt: reservation.expiresAt
            )
        }
        let plan = LaneLifecyclePlan(
            id: planIDGenerator(),
            kind: .recovery,
            createdAt: now,
            expiresAt: now.addingTimeInterval(10 * 60),
            laneID: laneID,
            reservationGeneration: reservation.generation,
            reservationToken: reservation.token,
            reservationThreadID: reservation.threadID,
            lastActivityAt: reservation.lastActivityAt,
            fingerprint: fingerprint
        )
        try planStore.save(plan)
        return plan
    }

    public func applyRecovery(
        planID: String,
        laneID: String,
        now: Date
    ) throws -> LaneReleaseResult {
        let global = try coordinator.acquire(
            identity: lifecycleIdentity(command: [
                "simlease", "lane", "recover", "apply", planID,
            ])
        )
        defer { global.release() }
        let initialState = try store.readState()
        let allLanes = try laneLocks.acquireAll(
            maxSlot: maximumSlot(in: initialState)
        )
        defer { allLanes.release() }
        let plan = try planStore.consume(id: planID, now: now)
        guard plan.kind == .recovery,
              plan.laneID == laneID else {
            throw LaneServiceError.targetMismatch(
                expected: plan.laneID ?? "recovery lane",
                actual: laneID
            )
        }
        var state = try store.readState()
        guard let reservationIndex = state.reservations.firstIndex(where: {
            $0.laneID == laneID
        }) else {
            throw LaneServiceError.recoveryRequired(laneID: laneID)
        }
        let reservation = state.reservations[reservationIndex]
        guard reservation.generation == plan.reservationGeneration,
              reservation.token == plan.reservationToken,
              reservation.threadID == plan.reservationThreadID,
              reservation.lastActivityAt == plan.lastActivityAt,
              reservation.udid == plan.fingerprint.udid else {
            throw LaneServiceError.recoveryRequired(laneID: laneID)
        }
        guard let managedIndex = state.managedDevices.firstIndex(where: {
            $0.udid == reservation.udid
        }) else {
            throw LaneServiceError.metadataError(
                "recovery target is not a managed simulator"
            )
        }
        let managed = state.managedDevices[managedIndex]
        let device = try provider.inventory().devices.first {
            $0.udid == reservation.udid
        }
        guard makeFingerprint(device: device, managed: managed) == plan.fingerprint else {
            throw LaneServiceError.recoveryRequired(laneID: laneID)
        }
        if let device,
           device.state.caseInsensitiveCompare("Shutdown") != .orderedSame {
            try provider.shutdownDevice(udid: device.udid)
        }
        state.reservations.remove(at: reservationIndex)
        state.managedDevices[managedIndex].lifecycle = device == nil
            ? .recoveryRequired
            : .idle
        try store.writeState(state)
        try? store.removeDescriptor(
            at: URL(fileURLWithPath: reservation.descriptorPath)
        )
        return LaneReleaseResult(
            laneID: laneID,
            udid: reservation.udid,
            state: state.managedDevices[managedIndex].lifecycle.rawValue,
            disposalPlanCommand: [
                "simlease", "lane", "dispose", "plan", reservation.udid,
            ]
        )
    }

    public func createDisposalPlan(
        udid: String,
        now: Date
    ) throws -> LaneLifecyclePlan {
        let state = try store.readState()
        guard !state.reservations.contains(where: { $0.udid == udid }),
              let managed = state.managedDevices.first(where: {
                  $0.udid == udid && $0.lifecycle == .idle
              }),
              let device = try provider.inventory().devices.first(where: {
                  $0.udid == udid
              }),
              fingerprintMatchesManaged(device, managed: managed),
              device.state.caseInsensitiveCompare("Shutdown") == .orderedSame else {
            throw LaneServiceError.metadataError(
                "disposal requires an idle, unreserved, shutdown managed simulator"
            )
        }
        let plan = LaneLifecyclePlan(
            id: planIDGenerator(),
            kind: .disposal,
            createdAt: now,
            expiresAt: now.addingTimeInterval(10 * 60),
            laneID: nil,
            reservationGeneration: nil,
            lastActivityAt: nil,
            fingerprint: makeFingerprint(device: device, managed: managed)
        )
        try planStore.save(plan)
        return plan
    }

    public func applyDisposal(
        planID: String,
        udid: String,
        now: Date
    ) throws -> LaneDisposalResult {
        let global = try coordinator.acquire(
            identity: lifecycleIdentity(command: [
                "simlease", "lane", "dispose", "apply", planID,
            ])
        )
        defer { global.release() }
        let initialState = try store.readState()
        let allLanes = try laneLocks.acquireAll(
            maxSlot: maximumSlot(in: initialState)
        )
        defer { allLanes.release() }
        let plan = try planStore.consume(id: planID, now: now)
        guard plan.kind == .disposal,
              plan.fingerprint.udid == udid else {
            throw LaneServiceError.targetMismatch(
                expected: plan.fingerprint.udid,
                actual: udid
            )
        }
        var state = try store.readState()
        guard !state.reservations.contains(where: { $0.udid == udid }),
              let managedIndex = state.managedDevices.firstIndex(where: {
                  $0.udid == udid && $0.lifecycle == .idle
              }) else {
            throw LaneServiceError.metadataError(
                "disposal target is reserved or is not an idle managed simulator"
            )
        }
        let managed = state.managedDevices[managedIndex]
        guard let device = try provider.inventory().devices.first(where: {
            $0.udid == udid
        }),
              fingerprintMatchesManaged(device, managed: managed),
              makeFingerprint(device: device, managed: managed) == plan.fingerprint,
              device.state.caseInsensitiveCompare("Shutdown") == .orderedSame else {
            throw LaneServiceError.metadataError(
                "managed simulator changed after disposal review"
            )
        }
        try provider.deleteDevice(udid: udid)
        state.managedDevices.remove(at: managedIndex)
        try store.writeState(state)
        return LaneDisposalResult(planID: planID, udid: udid, deleted: true)
    }

    private func makeFingerprint(
        device: LaneSimulatorDevice?,
        managed: ManagedSimulatorRecord
    ) -> ManagedSimulatorFingerprint {
        ManagedSimulatorFingerprint(
            udid: managed.udid,
            deviceTypeIdentifier: device?.deviceTypeIdentifier
                ?? managed.deviceTypeIdentifier,
            runtimeIdentifier: device?.runtimeIdentifier
                ?? managed.runtimeIdentifier,
            standardizedDataPath: URL(
                fileURLWithPath: device?.dataPath ?? managed.expectedDataPath
            ).standardizedFileURL.path,
            state: device?.state ?? "Missing"
        )
    }

    private func fingerprintMatchesManaged(
        _ device: LaneSimulatorDevice,
        managed: ManagedSimulatorRecord
    ) -> Bool {
        device.udid == managed.udid
            && device.deviceTypeIdentifier == managed.deviceTypeIdentifier
            && device.runtimeIdentifier == managed.runtimeIdentifier
            && device.dataPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            } == URL(fileURLWithPath: managed.expectedDataPath)
                .standardizedFileURL.path
    }

    private func maximumSlot(in state: LanePersistentState) -> Int {
        max(
            state.configuration.maxActive,
            state.reservations.map(\.slot).max() ?? 0
        )
    }

    private func lifecycleIdentity(command: [String]) -> LeaseIdentity {
        LeaseIdentity(
            pid: getpid(),
            cwd: FileManager.default.currentDirectoryPath,
            project: "SimLease",
            command: command,
            source: .terminal,
            threadID: nil,
            threadTitle: nil
        )
    }

    private func makeStatus(
        state: LanePersistentState,
        now: Date
    ) throws -> LaneStatusReport {
        let reserved = try state.reservations.sorted { $0.slot < $1.slot }.map {
            reservation -> LaneStatusEntry in
            let device = state.managedDevices.first { $0.udid == reservation.udid }
            let probe = try laneLocks.tryAcquire(slot: reservation.slot)
            let active = probe == nil
            probe?.release()
            return LaneStatusEntry(
                laneID: reservation.laneID,
                slot: reservation.slot,
                project: reservation.project,
                threadID: reservation.threadID,
                threadTitle: reservation.threadTitle,
                udid: reservation.udid,
                runtimeName: device?.runtimeName ?? "Unknown",
                deviceTypeName: device?.deviceTypeName ?? "Unknown",
                lastActivityAt: reservation.lastActivityAt,
                expiresAt: reservation.expiresAt,
                isCommandActive: active,
                recoveryRequired: reservation.expiresAt <= now
                    || device?.lifecycle == .recoveryRequired
            )
        }
        let occupied = Set(state.reservations.map(\.slot))
        let available = state.reservations.count >= state.configuration.maxActive
            ? []
            : (1...state.configuration.maxActive).filter { !occupied.contains($0) }
        return LaneStatusReport(
            schemaVersion: 1,
            configuration: state.configuration,
            reserved: reserved,
            availableSlots: available
        )
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(mapped)
        return result.isEmpty ? "Project" : result
    }
}
