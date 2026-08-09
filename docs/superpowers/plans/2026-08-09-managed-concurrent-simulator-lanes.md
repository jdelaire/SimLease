# Managed Concurrent Simulator Lanes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a SimLease-managed, two-lane-by-default simulator workflow that safely provisions one isolated simulator per agent, permits bounded concurrency, and gives agents exact human and JSON guidance.

**Architecture:** Keep the existing `LeaseCoordinator` lock as the global control and legacy-exclusive barrier. Add persistent lane state, one `lockf` command lock per slot, an injected CoreSimulator provider, and lane-aware shim validation. Lane commands briefly take the global lease before their slot; global mutations take the global lease and every slot in ascending order.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, Darwin POSIX locking, CryptoKit for reviewed-plan integrity, XCTest, zsh integration tests, `xcrun simctl`, and AXe's documented `--udid` selector.

## Global Constraints

- Support macOS 15 or later and Apple Silicon without adding package dependencies.
- Default to two active lanes; accept only positive configured limits.
- Use `schemaVersion: 1` for lane JSON contracts.
- Use a two-hour idle expiry refreshed by successful shim validation.
- Use ten-minute, one-use recovery and disposal plans.
- Never download a runtime, force-release an active owner, terminate a foreign process, delete automatically, or mutate a foreign simulator.
- Preserve `simlease status`, `simlease name`, `simlease hold`, cleanup, update, and no-lane shim behavior.
- Commands without a valid lane descriptor remain globally exclusive.
- Do not silently rewrite destinations, UDIDs, or DerivedData paths; fail with exact corrective guidance.
- Do not stage or commit unless the user explicitly authorizes it during execution.
- Do not install, publish, tag, push, or update the active SimLease release during this plan.
- Before any live simulator command, run `simlease status --json`, verify `xcodebuild`, `xcrun`, and `axe` resolve under `~/.local/lib/simlease/shims`, then obey the returned state.

---

## File Map

- `Sources/SimLeaseCore/LaneModels.swift`: public schema-v1 requests, descriptors, status, lifecycle plans, errors, and fingerprints.
- `Sources/SimLeaseCore/LaneStore.swift`: private persistent configuration, reservations, managed-device records, and descriptor files.
- `Sources/SimLeaseCore/LanePlanStore.swift`: integrity-protected, expiring, one-use recovery and disposal plans.
- `Sources/SimLeaseCore/LaneSimulatorProvider.swift`: local CoreSimulator inventory parsing and exact create/shutdown/delete operations.
- `Sources/SimLeaseCore/LaneLockCoordinator.swift`: per-slot `lockf` handles and ascending all-slot acquisition.
- `Sources/SimLeaseCore/LaneService.swift`: acquire, status, configuration, renewal, release, recovery, and disposal policy.
- `Sources/SimLeaseCore/LaneCommandPolicy.swift`: `xcodebuild`, `xcrun simctl`, and AXe target validation.
- `Sources/SimLeaseCLI/LaneFormatting.swift`: human guidance and stable JSON encoding.
- Existing CLI, cleanup, path, and installer files: narrow integration only.

---

### Task 1: Lane schemas and filesystem paths

**Files:**
- Create: `Sources/SimLeaseCore/LaneModels.swift`
- Modify: `Sources/SimLeaseCore/LeasePaths.swift:18-36`
- Create: `Tests/SimLeaseCoreTests/LaneModelsTests.swift`
- Modify: `Tests/SimLeaseCoreTests/LeaseModelsTests.swift`

**Interfaces:**
- Produces: `LaneConfiguration`, `LaneAcquireRequest`, `LaneDescriptor`, `LaneReservation`, `ManagedSimulatorRecord`, `LaneAcquireResult`, `LaneStatusReport`, `LaneConfigurationReport`, `LaneReleaseResult`, `LaneDisposalResult`, `LaneLifecyclePlan`, `ManagedSimulatorFingerprint`, and `LaneServiceError`.
- Produces paths: `laneRoot`, `laneState`, `laneDescriptors`, `lanePlans`, `laneCommandLock(slot:)`, `laneDerivedData`, and `laneResultBundles`.

- [ ] **Step 1: Write schema-v1 round-trip and path tests**

```swift
func testAcquireResultRoundTripsSchemaVersionOne() throws {
    let result = LaneAcquireResult(
        schemaVersion: 1,
        state: .acquired,
        lane: makeDescriptor(slot: 1),
        environment: ["SIMLEASE_LANE_FILE": "/tmp/lane.json"],
        xcodebuildArguments: ["-destination", "platform=iOS Simulator,id=UDID-1"],
        derivedDataPath: "/tmp/DerivedData",
        resultBundlePath: "/tmp/Results/lane-1.xcresult",
        releaseCommand: ["simlease", "lane", "release"],
        nextActions: []
    )
    let data = try JSONEncoder.simLease.encode(result)
    XCTAssertEqual(try JSONDecoder.simLease.decode(LaneAcquireResult.self, from: data), result)
}

func testLanePathsStayUnderCacheRoot() {
    let paths = LeasePaths(root: URL(fileURLWithPath: "/tmp/cache"))
    XCTAssertEqual(paths.laneCommandLock(slot: 2).path, "/tmp/cache/lanes/locks/lane-2.lock")
    XCTAssertEqual(paths.laneDerivedData.path, "/tmp/cache/lanes/DerivedData")
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --filter LaneModelsTests`

Expected: compile failure because lane types and paths do not exist.

- [ ] **Step 3: Add exact schema types**

Implement public `Codable`, `Equatable`, `Sendable` value types. Use these required fields:

```swift
public struct LaneConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let maxActive: Int
}

public struct LaneDescriptor: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let laneID: String
    public let slot: Int
    public let token: String
    public let project: String
    public let threadID: String?
    public let threadTitle: String?
    public let udid: String
    public let deviceTypeIdentifier: String
    public let deviceTypeName: String
    public let runtimeIdentifier: String
    public let runtimeName: String
    public let derivedDataPath: String
    public let acquiredAt: Date
    public let lastActivityAt: Date
    public let expiresAt: Date
}

public struct LaneAcquireRequest: Codable, Equatable, Sendable {
    public let project: String
    public let deviceType: String
    public let runtime: String
}

public struct LaneReservation: Codable, Equatable, Sendable {
    public let laneID: String
    public let slot: Int
    public let token: String
    public let project: String
    public let threadID: String?
    public let threadTitle: String?
    public let udid: String
    public let descriptorPath: String
    public let generation: Int
    public let acquiredAt: Date
    public let lastActivityAt: Date
    public let expiresAt: Date
}

public enum ManagedSimulatorLifecycle: String, Codable, Equatable, Sendable {
    case reserved
    case idle
    case recoveryRequired
    case disposalPlanned
}

public struct ManagedSimulatorRecord: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let deviceTypeIdentifier: String
    public let deviceTypeName: String
    public let runtimeIdentifier: String
    public let runtimeName: String
    public let expectedDataPath: String
    public let createdAt: Date
    public var lifecycle: ManagedSimulatorLifecycle
}

public struct ManagedSimulatorFingerprint: Codable, Equatable, Sendable {
    public let udid: String
    public let deviceTypeIdentifier: String
    public let runtimeIdentifier: String
    public let standardizedDataPath: String
    public let state: String
}

public enum LaneAcquireState: String, Codable, Equatable, Sendable {
    case acquired
    case capacityFull
}

public struct LaneAcquireResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let state: LaneAcquireState
    public let lane: LaneDescriptor?
    public let environment: [String: String]
    public let xcodebuildArguments: [String]
    public let derivedDataPath: String?
    public let resultBundlePath: String?
    public let releaseCommand: [String]
    public let nextActions: [String]
}

public struct LaneStatusEntry: Codable, Equatable, Sendable {
    public let laneID: String
    public let slot: Int
    public let project: String
    public let threadID: String?
    public let threadTitle: String?
    public let udid: String
    public let runtimeName: String
    public let deviceTypeName: String
    public let lastActivityAt: Date
    public let expiresAt: Date
    public let isCommandActive: Bool
    public let recoveryRequired: Bool
}

public struct LaneStatusReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configuration: LaneConfiguration
    public let reserved: [LaneStatusEntry]
    public let availableSlots: [Int]
}

public struct LaneConfigurationReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configuration: LaneConfiguration
    public let reservationCount: Int
}

public struct LaneReleaseResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let laneID: String
    public let udid: String
    public let state: String
    public let disposalPlanCommand: [String]
}

public struct LaneDisposalResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    public let udid: String
    public let deleted: Bool
}

public enum LaneLifecyclePlanKind: String, Codable, Equatable, Sendable {
    case recovery
    case disposal
}

public struct LaneLifecyclePlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let kind: LaneLifecyclePlanKind
    public let createdAt: Date
    public let expiresAt: Date
    public let laneID: String?
    public let reservationGeneration: Int?
    public let lastActivityAt: Date?
    public let fingerprint: ManagedSimulatorFingerprint
}
```

Define the exact error payloads:

```swift
public enum LaneServiceError: Error, Equatable {
    case capacityFull(LaneStatusReport)
    case runtimeUnavailable(requested: String, available: [String])
    case deviceTypeUnavailable(requested: String, available: [String])
    case invalidLaneDescriptor(String)
    case laneOwnershipMismatch(laneID: String)
    case targetMismatch(expected: String, actual: String?)
    case derivedDataMismatch(expected: String, actual: String?)
    case globalMutationBusy
    case laneRecoveryTooRecent(expiresAt: Date)
    case unsupportedAXeTargeting
    case recoveryRequired(laneID: String)
    case metadataError(String)
}
```

- [ ] **Step 4: Add lane paths under the existing cache root**

```swift
public var laneRoot: URL { root.appendingPathComponent("lanes", isDirectory: true) }
public var laneState: URL { laneRoot.appendingPathComponent("state.json") }
public var laneDescriptors: URL { laneRoot.appendingPathComponent("descriptors", isDirectory: true) }
public var lanePlans: URL { laneRoot.appendingPathComponent("plans", isDirectory: true) }
public var laneDerivedData: URL { laneRoot.appendingPathComponent("DerivedData", isDirectory: true) }
public var laneResultBundles: URL { laneRoot.appendingPathComponent("ResultBundles", isDirectory: true) }
public func laneCommandLock(slot: Int) -> URL {
    laneRoot.appendingPathComponent("locks/lane-\(slot).lock")
}
```

- [ ] **Step 5: Run focused tests and inspect diff**

Run: `swift test --filter LaneModelsTests`

Expected: all lane model tests pass.

Run: `git diff --check && git diff -- Sources/SimLeaseCore/LeasePaths.swift Sources/SimLeaseCore/LaneModels.swift Tests/SimLeaseCoreTests/LaneModelsTests.swift`

Expected: no whitespace errors; only schema and path changes. Do not stage or commit.

---

### Task 2: Private lane state and descriptor storage

**Files:**
- Create: `Sources/SimLeaseCore/LaneStore.swift`
- Create: `Tests/SimLeaseCoreTests/LaneStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 models and `LeasePaths`.
- Produces:

```swift
public protocol LaneStoring: Sendable {
    func readState() throws -> LanePersistentState
    func writeState(_ state: LanePersistentState) throws
    func writeDescriptor(_ descriptor: LaneDescriptor) throws -> URL
    func readDescriptor(at url: URL) throws -> LaneDescriptor
    func removeDescriptor(at url: URL) throws
}
```

- [ ] **Step 1: Write privacy, atomicity, corruption, and traversal tests**

```swift
func testCreatesPrivateDirectoriesAndDescriptor() throws {
    let store = try LaneStore(paths: paths)
    let url = try store.writeDescriptor(makeDescriptor(slot: 1))
    XCTAssertEqual(permissions(paths.laneRoot), 0o700)
    XCTAssertEqual(permissions(paths.laneDescriptors), 0o700)
    XCTAssertEqual(permissions(url), 0o600)
}

func testRejectsDescriptorOutsideManagedDirectory() throws {
    let store = try LaneStore(paths: paths)
    XCTAssertThrowsError(try store.readDescriptor(at: URL(fileURLWithPath: "/tmp/foreign.json")))
}
```

Also test default state (`schemaVersion: 1`, `maxActive: 2`), atomic replacement, corrupt JSON, duplicate slots, duplicate UDIDs, and a descriptor token that does not match its reservation.

- [ ] **Step 2: Run store tests and confirm RED**

Run: `swift test --filter LaneStoreTests`

Expected: compile failure because `LaneStore` and `LanePersistentState` do not exist.

- [ ] **Step 3: Implement one atomically replaced state file**

Use one `LanePersistentState` payload to avoid partially updating configuration, reservations, and managed devices:

```swift
public struct LanePersistentState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var configuration: LaneConfiguration
    public var reservations: [LaneReservation]
    public var managedDevices: [ManagedSimulatorRecord]
}
```

Create directories with mode `0700`. Write files using `open(O_CREAT | O_EXCL, 0600)`, complete write loops, `fsync`, `close`, and `rename`, matching `MetadataStore` safety. Standardize and containment-check every descriptor URL before reading or removing it.

- [ ] **Step 4: Enforce state invariants before every write**

Reject state unless:

- schema version equals `1`;
- `maxActive > 0`;
- slots are unique and within `1...maxActive` unless preserved during a cap reduction;
- reservation lane IDs, tokens, and UDIDs are non-empty and unique;
- each reservation references exactly one managed device;
- managed UUIDs and expected data paths are unique.

- [ ] **Step 5: Run store and existing metadata tests**

Run: `swift test --filter LaneStoreTests && swift test --filter MetadataStoreTests`

Expected: both suites pass.

Run: `git diff --check && git diff -- Sources/SimLeaseCore/LaneStore.swift Tests/SimLeaseCoreTests/LaneStoreTests.swift`

Expected: storage-only diff. Do not stage or commit.

---

### Task 3: Local CoreSimulator inventory and exact managed mutations

**Files:**
- Create: `Sources/SimLeaseCore/LaneSimulatorProvider.swift`
- Create: `Tests/SimLeaseCoreTests/LaneSimulatorProviderTests.swift`

**Interfaces:**
- Consumes: `CleanupCommandRunning` and Task 1 fingerprint/record types.
- Produces:

```swift
public protocol LaneSimulatorProviding: Sendable {
    func inventory() throws -> LaneSimulatorInventory
    func createDevice(name: String, deviceTypeID: String, runtimeID: String) throws -> String
    func shutdownDevice(udid: String) throws
    func deleteDevice(udid: String) throws
}

public struct LaneSimulatorInventory: Equatable, Sendable {
    public let runtimes: [LaneRuntime]
    public let deviceTypes: [LaneDeviceType]
    public let devices: [LaneSimulatorDevice]
}
```

- [ ] **Step 1: Write JSON parsing and command tests**

Use fixtures containing available/unavailable runtimes, duplicate display names, device types, booted/shutdown devices, and exact data paths. Assert these process calls:

```swift
["simctl", "list", "runtimes", "-j"]
["simctl", "list", "devicetypes", "-j"]
["simctl", "list", "devices", "-j"]
["simctl", "create", "[SimLease] ExplorerDex 1", "TYPE-ID", "RUNTIME-ID"]
["simctl", "shutdown", "UDID-1"]
["simctl", "delete", "UDID-1"]
```

Assert every child environment contains `SIMLEASE_HELD=1` so the provider cannot recurse through shims.

- [ ] **Step 2: Run provider tests and confirm RED**

Run: `swift test --filter LaneSimulatorProviderTests`

Expected: compile failure because provider types do not exist.

- [ ] **Step 3: Implement strict inventory parsers**

Decode only required CoreSimulator fields:

```swift
public struct LaneRuntime: Codable, Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let version: String
    public let isAvailable: Bool
}

public struct LaneDeviceType: Codable, Equatable, Sendable {
    public let identifier: String
    public let name: String
}

public struct LaneSimulatorDevice: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtimeIdentifier: String
    public let dataPath: String?
}
```

Reject malformed or incomplete JSON. Never infer a UUID or data path from a display name.

- [ ] **Step 4: Implement deterministic runtime/device-type resolution**

`latest` selects the highest numeric dotted version among locally available iOS runtimes. Exact runtime identifier or unique exact display name selects that runtime. Device type requires a unique exact identifier or case-insensitive exact display name. Empty, missing, unavailable, or ambiguous matches throw the named service error and return valid local choices at the CLI layer.

- [ ] **Step 5: Run focused tests and inspect diff**

Run: `swift test --filter LaneSimulatorProviderTests`

Expected: all provider tests pass without invoking real CoreSimulator.

Run: `git diff --check && git diff -- Sources/SimLeaseCore/LaneSimulatorProvider.swift Tests/SimLeaseCoreTests/LaneSimulatorProviderTests.swift`

Expected: provider-only diff. Do not stage or commit.

---

### Task 4: Per-slot locks and acquire/status/configure/release service

**Files:**
- Create: `Sources/SimLeaseCore/LaneLockCoordinator.swift`
- Create: `Sources/SimLeaseCore/LaneService.swift`
- Create: `Tests/SimLeaseCoreTests/LaneLockCoordinatorTests.swift`
- Create: `Tests/SimLeaseCoreTests/LaneServiceTests.swift`

**Interfaces:**
- Consumes: `LeaseCoordinator`, `LaneStoring`, `LaneSimulatorProviding`, `LeaseIdentity`, and Task 1 models.
- Produces:

```swift
public final class LaneLockHandle: @unchecked Sendable {
    public func release()
}

public final class LaneLockCoordinator: @unchecked Sendable {
    public func acquire(slot: Int) throws -> LaneLockHandle
    public func acquireAll(maxSlot: Int) throws -> LaneLockHandle
}

public protocol LaneServicing: Sendable {
    func acquire(request: LaneAcquireRequest, identity: LeaseIdentity) throws -> LaneAcquireResult
    func status(now: Date) throws -> LaneStatusReport
    func configure(maxActive: Int?) throws -> LaneConfigurationReport
    func renew(descriptorURL: URL, now: Date) throws -> LaneDescriptor
    func release(descriptorURL: URL, identity: LeaseIdentity) throws -> LaneReleaseResult
}
```

- [ ] **Step 1: Write multi-process lock tests**

Test that slot 1 and slot 2 can be held simultaneously, a second slot-1 holder blocks/times out, and `acquireAll(maxSlot: 2)` waits for both. Use child processes or `/usr/bin/lockf`; same-process POSIX locks are not valid contention proof.

- [ ] **Step 2: Run lock tests and confirm RED**

Run: `swift test --filter LaneLockCoordinatorTests`

Expected: compile failure because lane lock coordinator does not exist.

- [ ] **Step 3: Implement private `0600` lock files and ascending acquisition**

Open every lock with `O_CREAT | O_RDWR`, call `fchmod(0600)`, and acquire with `lockf`. `acquireAll` must acquire `1...maxSlot` and release already-held descriptors on any error. `LaneLockHandle.release()` must be idempotent.

- [ ] **Step 4: Write service RED tests**

Cover:

- default capacity two and third acquire returns `capacityFull` without provider mutation;
- lowering capacity below an occupied slot blocks every new acquire until total reservations fall below the configured maximum;
- compatible idle managed device is reused;
- otherwise one exact device is created under global lease plus all lane locks;
- descriptor mode is `0600` and result contains exact destination/DerivedData guidance;
- unique project/slot DerivedData and result-bundle paths;
- `latest` uses only local available inventory;
- max reduction does not evict reservations above the new cap;
- status reports `isCommandActive` from a non-blocking slot-lock probe without taking ownership away from the running command;
- renewal moves `lastActivityAt` and `expiresAt` by two hours;
- release rejects wrong token, waits for the slot, shuts down exact managed UUID, removes reservation, and does not delete.

- [ ] **Step 5: Implement minimum lane service**

Use this lock order everywhere. Any state read used to choose a slot must be
repeated after the required slot lock is held:

```text
LeaseCoordinator global lease -> lane slot lock(s) ascending -> state read/revalidation -> mutation
```

Acquire flow:

1. acquire global lease with requesting identity;
2. read and validate state; if `reservations.count >= maxActive`, return `capacityFull`; otherwise choose the lowest unreserved slot in `1...maxActive`;
3. acquire that slot, or every slot when creation is required;
4. re-read state and confirm the candidate slot remains available;
5. resolve inventory and a compatible idle managed device;
6. create only while every slot is held when no compatible device exists;
7. query inventory again and require returned UUID/data path agreement;
8. write reservation/state, then private descriptor;
9. release locks and return schema-v1 result.

If descriptor writing fails, roll state back and retain any newly created device as an idle managed device; do not delete during rollback.

- [ ] **Step 6: Run core lane suites and inspect diff**

Run: `swift test --filter LaneLockCoordinatorTests && swift test --filter LaneServiceTests`

Expected: all lock and service tests pass.

Run: `git diff --check && git diff -- Sources/SimLeaseCore/LaneLockCoordinator.swift Sources/SimLeaseCore/LaneService.swift Tests/SimLeaseCoreTests/LaneLockCoordinatorTests.swift Tests/SimLeaseCoreTests/LaneServiceTests.swift`

Expected: lock/service-only diff. Do not stage or commit.

---

### Task 5: Lane CLI parsing, JSON, and human guidance

**Files:**
- Modify: `Sources/SimLeaseCLI/CommandParser.swift:3-125`
- Modify: `Sources/SimLeaseCLI/CLI.swift:6-161`
- Create: `Sources/SimLeaseCLI/LaneFormatting.swift`
- Modify: `Tests/SimLeaseCLITests/CommandParserTests.swift`
- Create: `Tests/SimLeaseCLITests/LaneCLITests.swift`

**Interfaces:**
- Consumes: `LaneServicing` from Task 4.
- Produces parser cases:

```swift
case laneAcquire(project: String, deviceType: String, runtime: String, json: Bool)
case laneStatus(json: Bool)
case laneConfig(maxActive: Int?, json: Bool)
case laneRelease(json: Bool)
```

- [ ] **Step 1: Write parser RED tests for every accepted and rejected shape**

Accepted examples:

```swift
["simlease", "lane", "acquire", "--project", "ExplorerDex", "--device-type", "iPhone 17 Pro", "--runtime", "latest", "--json"]
["simlease", "lane", "status", "--json"]
["simlease", "lane", "config"]
["simlease", "lane", "config", "--max-active", "2", "--json"]
["simlease", "lane", "release", "--json"]
```

Reject missing values, duplicate flags, unknown flags, non-positive limits, extra positional values, and `release` without `SIMLEASE_LANE_FILE` at the CLI boundary.

- [ ] **Step 2: Run parser tests and confirm RED**

Run: `swift test --filter CommandParserTests`

Expected: failures because lane commands are unsupported.

- [ ] **Step 3: Implement parser and injected service seam**

Add `laneService: (any LaneServicing)?` to `CLIConfiguration`. Production construction creates the real provider, store, locks, and service; tests inject a stub. Change usage to:

```text
Usage: simlease <status|name|hold|lane|clean|update|--version>
```

- [ ] **Step 4: Write human and JSON contract tests**

Assert JSON decodes as `LaneAcquireResult` and human acquire output contains all five required elements:

```text
Acquired lane-1
UDID: UDID-1
export SIMLEASE_LANE_FILE="/tmp/simlease-test/lanes/descriptors/lane-1.json"
-destination 'platform=iOS Simulator,id=UDID-1'
-resultBundlePath '/tmp/simlease-test/lanes/ResultBundles/lane-1/run-1.xcresult'
simlease lane release
```

Assert capacity-full output says what was observed, why no lane was allocated, that no state changed, current owners, and the exact retry command. Assert runtime/device errors print valid local choices.

- [ ] **Step 5: Implement formatting and exit mapping**

Use exit `0` for successful acquire/status/config/release, `64` for usage, `74` for metadata/inventory failures, `75` for capacity/busy states, and `76` for refused recovery/disposal policy states added later. Send valid requested JSON to stdout; send human errors to stderr.

- [ ] **Step 6: Run CLI suites and inspect diff**

Run: `swift test --filter CommandParserTests && swift test --filter LaneCLITests && swift test --filter CLIScaffoldTests`

Expected: all parser, lane CLI, and existing scaffold tests pass.

Run: `git diff --check && git diff -- Sources/SimLeaseCLI Tests/SimLeaseCLITests`

Expected: lane CLI integration only. Do not stage or commit.

---

### Task 6: Lane-aware shim enforcement and legacy global exclusion

**Files:**
- Create: `Sources/SimLeaseCore/LaneCommandPolicy.swift`
- Modify: `Sources/SimLeaseCore/ProtectedCommand.swift:3-72`
- Modify: `Sources/SimLeaseCLI/CLI.swift:378-481`
- Create: `Tests/SimLeaseCoreTests/LaneCommandPolicyTests.swift`
- Modify: `Tests/SimLeaseCoreTests/ProtectedCommandTests.swift`
- Modify: `Tests/SimLeaseCLITests/CLIScaffoldTests.swift`

**Interfaces:**
- Consumes: `LaneDescriptor`, `LaneStoring`, `LaneServicing.renew`, `LaneLockCoordinator`, and existing `ChildProcessRunner`.
- AXe syntax source: `https://github.com/cameroncooke/AXe` documents `--udid` followed by the simulator UDID for inspection, interaction, typing, and screenshots.
- Produces:

```swift
public enum LaneCommandScope: Equatable, Sendable {
    case passThrough
    case lane(slot: Int)
    case global
}

public enum LaneCommandPolicy {
    public static func validate(
        invocation: [String],
        descriptor: LaneDescriptor?
    ) throws -> LaneCommandScope
}
```

- [ ] **Step 1: Write command-policy RED tests**

Required lane-valid examples:

```swift
["xcodebuild", "test", "-destination", "platform=iOS Simulator,id=UDID-1", "-derivedDataPath", "/lane/DerivedData"]
["xcrun", "simctl", "boot", "UDID-1"]
["xcrun", "simctl", "install", "UDID-1", "/tmp/App.app"]
["axe", "describe-ui", "--udid", "UDID-1"]
["axe", "tap", "--label", "Continue", "--udid", "UDID-1"]
```

Require exact failure for missing/wrong `id=`, missing/wrong DerivedData, wrong simctl target, missing/duplicate/wrong AXe `--udid`, and AXe `list-simulators` as global. Classify `simctl create`, `clone`, `delete`, `erase`, `rename`, `runtime`, `list`, and unknown verbs as global.

Device-scoped simctl allowlist for schema v1:

```swift
let deviceScopedVerbs: Set<String> = [
    "boot", "bootstatus", "shutdown", "install", "uninstall", "launch",
    "terminate", "spawn", "openurl", "privacy", "push", "status_bar",
    "ui", "keychain", "location", "io", "pbcopy", "pbpaste",
    "get_app_container", "listapps",
]
```

- [ ] **Step 2: Run policy tests and confirm RED**

Run: `swift test --filter LaneCommandPolicyTests`

Expected: compile failure because policy does not exist.

- [ ] **Step 3: Implement strict non-rewriting validation**

Parse both `-destination VALUE` and `-destination=VALUE`, but require one simulator destination containing `id=` followed by `descriptor.udid`. Parse both `-derivedDataPath VALUE` and `-derivedDataPath=VALUE`, but require exact standardized lane path. AXe uses its documented `--udid` option followed by `descriptor.udid`. Unknown or ambiguous invocation becomes global, never lane-scoped.

- [ ] **Step 4: Change shim lock routing**

Lane command flow:

1. resolve and validate `SIMLEASE_LANE_FILE` under managed descriptor root;
2. acquire existing global `LeaseCoordinator` lease;
3. read descriptor and reservation, then acquire descriptor slot lock;
4. re-read state, validate reservation/token, and renew two-hour expiry;
5. release global lease;
6. run child with `SIMLEASE_HELD=1`;
7. release slot lock.

Legacy/global flow:

1. acquire existing global lease;
2. acquire every configured slot lock ascending;
3. reject any explicit target that is a reserved managed UDID without its descriptor;
4. run child with `SIMLEASE_HELD=1`;
5. release all slot locks, then global lease.

Update `simlease hold` to acquire every configured slot after the global lease and hold both until interrupted.

- [ ] **Step 5: Add real subprocess exclusion tests**

Using fake tools, prove:

- lane 1 and lane 2 child processes overlap;
- two commands in lane 1 serialize;
- legacy no-lane command waits for lane 1 and lane 2;
- manual hold waits for lane commands;
- wrong lane target never starts child;
- child exit code and signal forwarding remain unchanged;
- nested shim call with `SIMLEASE_HELD=1` does not deadlock.

- [ ] **Step 6: Run shim suites and inspect diff**

Run: `swift test --filter LaneCommandPolicyTests && swift test --filter ProtectedCommandTests && swift test --filter CLIScaffoldTests`

Expected: all policy and subprocess tests pass.

Run: `git diff --check && git diff -- Sources/SimLeaseCore/LaneCommandPolicy.swift Sources/SimLeaseCore/ProtectedCommand.swift Sources/SimLeaseCLI/CLI.swift Tests/SimLeaseCoreTests Tests/SimLeaseCLITests/CLIScaffoldTests.swift`

Expected: shim policy/coordination diff only. Do not stage or commit.

---

### Task 7: Explicit recovery and disposal plans

**Files:**
- Create: `Sources/SimLeaseCore/LanePlanStore.swift`
- Modify: `Sources/SimLeaseCore/LaneService.swift`
- Modify: `Sources/SimLeaseCLI/CommandParser.swift`
- Modify: `Sources/SimLeaseCLI/CLI.swift`
- Modify: `Sources/SimLeaseCLI/LaneFormatting.swift`
- Create: `Tests/SimLeaseCoreTests/LanePlanStoreTests.swift`
- Modify: `Tests/SimLeaseCoreTests/LaneServiceTests.swift`
- Modify: `Tests/SimLeaseCLITests/CommandParserTests.swift`
- Modify: `Tests/SimLeaseCLITests/LaneCLITests.swift`

**Interfaces:**
- Consumes: Task 1 plan/fingerprint models, `LaneStoring`, provider inventory, global lease, and all-slot locks.
- Adds to `LaneServicing`:

```swift
func createRecoveryPlan(laneID: String, now: Date) throws -> LaneLifecyclePlan
func applyRecovery(planID: String, laneID: String, now: Date) throws -> LaneReleaseResult
func createDisposalPlan(udid: String, now: Date) throws -> LaneLifecyclePlan
func applyDisposal(planID: String, udid: String, now: Date) throws -> LaneDisposalResult
```

- [ ] **Step 1: Write integrity and expiry RED tests**

Mirror `CleanupPlanStoreTests`: mode `0700` directory, `0600` file, SHA-256 payload digest, six-character uppercase/digit ID, duplicate refusal, ten-minute expiry, one-time consumption, changed-payload rejection, and unrelated-file preservation.

- [ ] **Step 2: Run plan-store tests and confirm RED**

Run: `swift test --filter LanePlanStoreTests`

Expected: compile failure because store does not exist.

- [ ] **Step 3: Implement `LanePlanStore`**

```swift
public protocol LanePlanStoring: Sendable {
    func save(_ plan: LaneLifecyclePlan) throws
    func consume(id: String, now: Date) throws -> LaneLifecyclePlan
    func prune(now: Date) throws
}
```

Use the existing cleanup plan's atomic-write and digest pattern, but separate lane plan directory and model.

- [ ] **Step 4: Write recovery/disposal policy RED tests**

Recovery plan requires either expired two-hour inactivity or inconsistent metadata. Apply must fail when command lock is held, activity resumed, token/owner changed, device fingerprint changed, plan expired/consumed, or target changed. Successful recovery may shut down exact managed device, releases reservation, retains device record, and never deletes.

Disposal plan requires idle, unreserved, shutdown SimLease-managed device. Apply must re-query inventory and fail for booted state, new reservation, UUID/data-path/runtime/type mismatch, foreign UUID, active command, expired/consumed plan, or target mismatch. Successful apply calls `deleteDevice` exactly once and removes only matching managed record.

- [ ] **Step 5: Implement service methods under global plus all-slot locks**

Plan creation is read-only but captures exact reservation generation, last activity, UUID, runtime ID, device type ID, state, and standardized data path. Apply consumes the plan only after acquiring the global lease and every slot lock, then revalidates all captured fields against fresh state and fresh inventory before mutation.

- [ ] **Step 6: Add parser and CLI commands**

Accepted shapes:

```text
simlease lane recover plan LANE-ID [--json]
simlease lane recover apply PLAN-ID --lane LANE-ID [--json]
simlease lane dispose plan SIMULATOR-UDID [--json]
simlease lane dispose apply PLAN-ID --target SIMULATOR-UDID [--json]
```

Human plan output must state exact target, fingerprint, expiry, no-change-yet status, and apply command. Human apply output must state exact shutdown/release or deletion result.

- [ ] **Step 7: Run lifecycle suites and inspect diff**

Run: `swift test --filter LanePlanStoreTests && swift test --filter LaneServiceTests && swift test --filter CommandParserTests && swift test --filter LaneCLITests`

Expected: all lifecycle and CLI tests pass.

Run: `git diff --check && git diff -- Sources/SimLeaseCore/LanePlanStore.swift Sources/SimLeaseCore/LaneService.swift Sources/SimLeaseCLI Tests/SimLeaseCoreTests/LanePlanStoreTests.swift Tests/SimLeaseCoreTests/LaneServiceTests.swift Tests/SimLeaseCLITests`

Expected: recovery/disposal diff only. Do not stage or commit.

---

### Task 8: Cleanup protection, packaging, documentation, and final verification

**Files:**
- Modify: `Sources/SimLeaseCore/CleanupModels.swift`
- Modify: `Sources/SimLeaseCore/CleanupPlanner.swift`
- Modify: `Sources/SimLeaseCLI/CLI.swift:206-349`
- Modify: `Tests/SimLeaseCoreTests/CleanupPlannerTests.swift`
- Modify: `Tests/SimLeaseCLITests/CleanupCLITests.swift`
- Create: `Tests/SmokeTests/lane-smoke.zsh`
- Modify: `Tests/InstallationTests/package-app.zsh:19-26`
- Modify: `README.md:1-70`

**Interfaces:**
- Consumes: complete lane state/status and CLI.
- Produces: cleanup protection for reserved managed devices and lane DerivedData paths; fake-provider process smoke proof; paste-ready agent instructions.

- [ ] **Step 1: Write cleanup protection RED tests**

Add `CleanupProtectionReason.managedLane`. Extend planner input with:

```swift
public struct LaneProtectionSnapshot: Equatable, Sendable {
    public let reservedDeviceIDs: Set<String>
    public let activeDerivedDataPaths: Set<String>
    public let activeResultBundlePaths: Set<String>
}
```

Assert reserved managed UUIDs are protected even when old and shutdown. Assert active/reserved lane DerivedData and result-bundle paths never appear as deletable storage. Assert idle, unreserved managed devices remain governed by normal cleanup age rules unless a lane disposal plan owns deletion.

- [ ] **Step 2: Run cleanup tests and confirm RED**

Run: `swift test --filter CleanupPlannerTests && swift test --filter CleanupCLITests`

Expected: failures because lane protection is not wired.

- [ ] **Step 3: Wire lane protection without changing unrelated cleanup policy**

Read a protection snapshot under the global lease when constructing cleanup service. Pass reserved UUIDs to `CleanupPlanner.makeReview` and append active lane DerivedData paths to protected active paths. If lane metadata is corrupt, defer simulator-device and lane-cache cleanup rather than treating targets as safe.

- [ ] **Step 4: Add fake-provider lane smoke test**

`Tests/SmokeTests/lane-smoke.zsh` must use `SIMLEASE_CACHE_ROOT`, temporary shims, and a fake underlying `xcrun` that returns deterministic inventory. Prove acquire output, two slots, third-request exit `75`, distinct UDIDs/DerivedData, two concurrent fake child commands, same-lane serialization, release/reuse, recovery-plan guards, disposal revalidation, and no foreign delete command.

- [ ] **Step 5: Update package usage assertion and README**

Package test must require usage text to contain `lane`. README agent section must include:

```sh
lane_json="$(mktemp)"
simlease lane acquire --project Project --device-type "iPhone 17 Pro" --runtime latest --json >"$lane_json"
export SIMLEASE_LANE_FILE="$(plutil -extract environment.SIMLEASE_LANE_FILE raw -o - "$lane_json")"
lane_udid="$(plutil -extract lane.udid raw -o - "$lane_json")"
lane_derived_data="$(plutil -extract derivedDataPath raw -o - "$lane_json")"
lane_result_bundle="$(plutil -extract resultBundlePath raw -o - "$lane_json")"
xcodebuild test -scheme App -destination "platform=iOS Simulator,id=$lane_udid" -derivedDataPath "$lane_derived_data" -resultBundlePath "$lane_result_bundle"
simlease lane release
rm -f "$lane_json"
```

Document capacity, no force-release, local-runtime-only selection, two-hour recovery, reusable idle pool, explicit two-step disposal, legacy global mode, and separate live simulator/device proof.

- [ ] **Step 6: Run focused and full non-simulator verification**

Run:

```sh
swift test --filter Lane
swift test
zsh Tests/SmokeTests/lane-smoke.zsh
zsh Tests/InstallationTests/package-app.zsh
```

Expected: every command exits `0`; `swift test` reports non-zero executed tests; smoke log shows no foreign delete.

- [ ] **Step 7: Classify live simulator smoke as a separate authorization gate**

Run:

```sh
simlease status --json
command -v xcodebuild
command -v xcrun
command -v axe
```

Required before continuing:

- status state is `free`;
- all three tool paths begin with `/Users/jdelaire/.local/lib/simlease/shims/`.

The active canonical shims contain the installed release, not the uninstalled
candidate. Therefore this plan does not run live lane commands by bypassing
those shims or replacing them implicitly. Report live lane validation as
blocked until the user separately authorizes installing the candidate into the
canonical SimLease-managed paths.

After that separate authorization, rerun the preflight. If free and all paths
are canonical, acquire two lanes, verify distinct UDIDs, boot each, run one
harmless device-scoped command per lane concurrently, release both, reacquire
one to prove reuse, and create—but do not apply—a disposal plan unless live
deletion receives separate authorization.

Expected after authorized installation: two distinct managed simulators;
concurrent commands finish; release leaves both shutdown and managed; no
deletion occurs.

If preflight reports `leased`, continue non-simulator verification or recheck
later. If it reports `metadataError`, or any shim path is wrong, stop live
validation and report the exact blocker.

- [ ] **Step 8: Inspect complete final diff and report gates**

Run:

```sh
git status --short
git diff --check
git diff --stat
git diff
```

Expected: only planned source, test, README, design, and plan files changed. Report unit, integration, packaging, and live simulator proof separately. Do not stage, commit, install, publish, tag, or push.
