# Stale Simulator Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a two-step CLI and menu-bar cleanup flow for shutdown simulator devices unused for 30 days and Apple-reported outdated runtimes.

**Architecture:** Cleanup models, inventory, planning, persistence, and execution live in `SimLeaseCore`. The CLI calls that shared engine directly; the menu invokes the bundled CLI with JSON and projects the same `CleanupReview` and `CleanupResult` models into a native review window. Planning and applying use non-waiting SimLease acquisition, and apply revalidates every exact target before deletion.

**Tech Stack:** Swift 6.4, Swift Package Manager, Foundation, CryptoKit, SwiftUI, AppKit, XCTest, `xcrun simctl`, macOS 15+

## Global Constraints

- Device eligibility requires `state == Shutdown` and Apple-reported `lastUsedAt` at least 30 days old.
- Missing device age, UUID/path agreement, or required inventory data protects the device.
- Runtime eligibility requires membership in `simctl runtime delete --outdated --dry-run`.
- Booted devices and every runtime used by a booted device are always protected.
- Active `xcodebuild` test actions block planning and applying.
- Planning and applying fail immediately when the SimLease is busy; they never wait behind an owner.
- Every apply requires a stored, unexpired six-character confirmation ID.
- Apply may delete only exact targets from that plan; new candidates are ignored.
- Re-enumerate globally and immediately before each deletion.
- Delete devices before runtimes; runtime apply always uses an exact runtime image identifier.
- No automatic cleanup, scheduling, force release, age override, inline UUID, broad runtime apply, or per-target selection.
- Automated tests use fake executables and temporary cache roots; they never delete real simulator state.
- Real-machine validation stops after read-only planning until the user approves the exact refreshed plan.
- Preserve the existing custom AXe installation and separate SimLease shim directory.
- Preserve all existing dirty workspace changes.
- The current core/menu implementation is intentionally uncommitted. Do not stage or commit implementation files unless the user separately authorizes commits. Commit steps below are conditional checkpoints.

---

### Task 1: Cleanup contracts and non-waiting lease acquisition

**Files:**
- Modify: `Sources/SimLeaseCore/LeasePaths.swift`
- Modify: `Sources/SimLeaseCore/LeaseCoordinator.swift`
- Create: `Sources/SimLeaseCore/CleanupModels.swift`
- Modify: `Tests/SimLeaseCoreTests/LeaseCoordinatorTests.swift`
- Create: `Tests/SimLeaseCoreTests/CleanupModelsTests.swift`

**Interfaces:**
- Consumes: existing `LeasePaths`, `LeaseIdentity`, `LeaseOwner`, `LeaseHandle`
- Produces: `LeaseCoordinator.tryAcquire(identity:)`, cleanup Codable models, `LeasePaths.cleanupPlans`

- [ ] **Step 1: Write failing immediate-acquisition tests**

Add to `LeaseCoordinatorTests`:

```swift
func testTryAcquireReturnsNilWithoutCreatingWaiterWhenBusy() throws {
    let fixture = try ProcessLeaseFixture()
    defer { fixture.stopHolder() }
    try fixture.startHolder()

    let handle = try fixture.coordinator.tryAcquire(identity: fixture.identity)

    XCTAssertNil(handle)
    XCTAssertEqual(try fixture.store.readWaiters(), [])
}

func testTryAcquireWritesOwnerAndReturnsHandleWhenFree() throws {
    let fixture = try ProcessLeaseFixture()

    let handle = try XCTUnwrap(
        fixture.coordinator.tryAcquire(identity: fixture.identity)
    )

    XCTAssertEqual(try fixture.coordinator.status().state, .leased)
    handle.release()
    XCTAssertEqual(try fixture.coordinator.status().state, .free)
}
```

- [ ] **Step 2: Run immediate-acquisition tests and verify failure**

Run:

```bash
swift test --filter LeaseCoordinatorTests/testTryAcquire
```

Expected: compile failure because `tryAcquire(identity:)` does not exist.

- [ ] **Step 3: Implement non-waiting lease acquisition**

Add:

```swift
public func tryAcquire(identity: LeaseIdentity) throws -> LeaseHandle? {
    let descriptor = try openLock()
    guard lockf(descriptor, F_TLOCK, 0) == 0 else {
        let code = errno
        _ = close(descriptor)
        guard code == EACCES || code == EAGAIN else {
            throw LeaseAcquisitionError.systemCall("lockf", code)
        }
        return nil
    }

    let owner = LeaseOwner(
        pid: identity.pid,
        acquiredAt: clock.wallNow(),
        cwd: identity.cwd,
        project: identity.project,
        command: identity.command,
        source: identity.source,
        threadID: identity.threadID,
        threadTitle: identity.threadTitle
    )
    do {
        try store.writeOwner(owner)
        return LeaseHandle(owner: owner, store: store, fileDescriptor: descriptor)
    } catch {
        _ = lockf(descriptor, F_ULOCK, 0)
        _ = close(descriptor)
        throw error
    }
}
```

- [ ] **Step 4: Write failing cleanup-model round-trip tests**

Define tests for these exact public contracts:

```swift
let target = CleanupTarget(
    kind: .device,
    identifier: "A581B51F-3BEC-4957-B796-8A058AD2EDBC",
    name: "iPhone 17 Pro",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    lastUsedAt: Date(timeIntervalSince1970: 100),
    sizeBytes: 4_096
)
let plan = CleanupPlan(
    id: "ABC123",
    createdAt: Date(timeIntervalSince1970: 200),
    expiresAt: Date(timeIntervalSince1970: 800),
    devices: [target],
    runtimes: [],
    protected: [],
    estimatedBytes: 4_096,
    availableBytesBefore: 50_000
)
let decoded = try JSONDecoder.simLease.decode(
    CleanupPlan.self,
    from: JSONEncoder.simLease.encode(plan)
)
XCTAssertEqual(decoded, plan)
```

Also assert:

```swift
XCTAssertEqual(
    CleanupResult(
        planID: "ABC123",
        items: [
            CleanupItemResult(
                target: target,
                outcome: .skipped,
                message: "Device became booted"
            )
        ],
        estimatedBytes: 4_096,
        availableBytesBefore: 50_000,
        availableBytesAfter: 50_000
    ).isPartial,
    true
)
```

- [ ] **Step 5: Run model tests and verify failure**

Run:

```bash
swift test --filter CleanupModelsTests
```

Expected: compile failure because cleanup model types do not exist.

- [ ] **Step 6: Implement cleanup models and paths**

Create:

```swift
public enum CleanupTargetKind: String, Codable, Equatable, Sendable {
    case device
    case runtime
}

public struct CleanupTarget: Codable, Equatable, Sendable {
    public let kind: CleanupTargetKind
    public let identifier: String
    public let name: String
    public let runtimeIdentifier: String
    public let lastUsedAt: Date?
    public let sizeBytes: Int64?
}

public enum CleanupProtectionReason: String, Codable, Equatable, Sendable {
    case activeTests
    case booted
    case bootedRuntime
    case invalidDataPath
    case missingIdentifier
    case missingLastUsedAt
    case notOldEnough
    case notOutdated
}

public struct ProtectedCleanupTarget: Codable, Equatable, Sendable {
    public let target: CleanupTarget
    public let reason: CleanupProtectionReason
    public let explanation: String
}

public struct CleanupPlan: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let expiresAt: Date
    public let devices: [CleanupTarget]
    public let runtimes: [CleanupTarget]
    public let protected: [ProtectedCleanupTarget]
    public let estimatedBytes: Int64
    public let availableBytesBefore: Int64?
}

public struct CleanupReview: Codable, Equatable, Sendable {
    public let plan: CleanupPlan?
    public let protected: [ProtectedCleanupTarget]
    public let estimatedBytes: Int64
}

public enum CleanupItemOutcome: String, Codable, Equatable, Sendable {
    case deleted
    case skipped
    case failed
}

public struct CleanupItemResult: Codable, Equatable, Sendable {
    public let target: CleanupTarget
    public let outcome: CleanupItemOutcome
    public let message: String
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public let planID: String
    public let items: [CleanupItemResult]
    public let estimatedBytes: Int64
    public let availableBytesBefore: Int64?
    public let availableBytesAfter: Int64?

    public var isPartial: Bool {
        items.contains { $0.outcome != .deleted }
    }
}
```

Add:

```swift
public var cleanupPlans: URL {
    root.appendingPathComponent("cleanup-plans", isDirectory: true)
}
```

Use explicit public memberwise initializers matching the tests.

- [ ] **Step 7: Run Task 1 tests**

Run:

```bash
swift test --filter LeaseCoordinatorTests
swift test --filter CleanupModelsTests
```

Expected: all selected tests pass.

- [ ] **Step 8: Conditional commit checkpoint**

If implementation commits are authorized and the existing SimLease base has
already been committed:

```bash
git add Sources/SimLeaseCore/LeasePaths.swift \
  Sources/SimLeaseCore/LeaseCoordinator.swift \
  Sources/SimLeaseCore/CleanupModels.swift \
  Tests/SimLeaseCoreTests/LeaseCoordinatorTests.swift \
  Tests/SimLeaseCoreTests/CleanupModelsTests.swift
git commit -m "feat: define simulator cleanup contracts"
```

Otherwise leave files unstaged and continue.

---

### Task 2: Literal CoreSimulator inventory

**Files:**
- Create: `Sources/SimLeaseCore/CleanupInventory.swift`
- Create: `Sources/SimLeaseCore/CleanupCommandRunner.swift`
- Create: `Tests/SimLeaseCoreTests/CleanupInventoryTests.swift`
- Create: `Tests/SimLeaseCoreTests/CleanupCommandRunnerTests.swift`

**Interfaces:**
- Consumes: `CleanupTarget`, `JSONDecoder.simLease`
- Produces: `CleanupInventoryProviding.inventory()`, `deleteDevice(id:)`, `deleteRuntime(id:)`, `CleanupInventory`

- [ ] **Step 1: Write failing inventory decoding test**

Use literal device JSON:

```swift
let devices = Data(#"""
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{
      "dataPath": "/Users/test/Library/Developer/CoreSimulator/Devices/DEVICE-1/data",
      "dataPathSize": 4096,
      "udid": "DEVICE-1",
      "lastUsedAt": "2026-06-01T00:00:00Z",
      "isAvailable": true,
      "state": "Shutdown",
      "name": "iPhone 17 Pro"
    }]
  }
}
"""#.utf8)
let decoded = try CleanupInventoryParser.decodeDevices(from: devices)
XCTAssertEqual(decoded.first?.identifier, "DEVICE-1")
XCTAssertEqual(decoded.first?.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
XCTAssertEqual(decoded.first?.sizeBytes, 4096)
```

Use literal runtime JSON keyed by image UUID:

```swift
let runtimes = Data(#"""
{
  "RUNTIME-IMAGE-1": {
    "build": "23T239",
    "deletable": true,
    "identifier": "RUNTIME-IMAGE-1",
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-4",
    "sizeBytes": 3931694170,
    "version": "26.4"
  }
}
"""#.utf8)
```

Assert dry-run parsing accepts only exact identifiers present in runtime JSON.
Fixture output:

```text
Would delete RUNTIME-IMAGE-1
```

Unknown lines or names that cannot map to exactly one known runtime image
identifier must throw
`CleanupInventoryError.invalidRuntimeDryRun`.

- [ ] **Step 2: Run inventory tests and verify failure**

Run:

```bash
swift test --filter CleanupInventoryTests
```

Expected: compile failure because inventory types do not exist.

- [ ] **Step 3: Implement raw inventory records and parser**

Define:

```swift
public struct CleanupDeviceRecord: Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let runtimeIdentifier: String
    public let state: String
    public let lastUsedAt: Date?
    public let dataPath: String?
    public let sizeBytes: Int64?
}

public struct CleanupRuntimeRecord: Equatable, Sendable {
    public let identifier: String
    public let runtimeIdentifier: String
    public let name: String
    public let build: String
    public let sizeBytes: Int64?
}

public struct CleanupInventory: Equatable, Sendable {
    public let devices: [CleanupDeviceRecord]
    public let runtimes: [CleanupRuntimeRecord]
    public let outdatedRuntimeIDs: Set<String>
    public let hasActiveXcodeTests: Bool
    public let availableBytes: Int64?
}

public enum CleanupInventoryError: Error, Equatable {
    case commandFailed(arguments: [String], code: Int32, stderr: String)
    case invalidDevicesJSON
    case invalidRuntimesJSON
    case invalidRuntimeDryRun
}
```

`CleanupInventoryParser` must:

- decode ISO-8601 `lastUsedAt`
- retain missing age and size as `nil`
- derive device runtime from the `devices` dictionary key
- derive runtime display name as `"<runtimeIdentifier> (<build>)"`
- map each non-empty dry-run line to one exact known image identifier token
- reject lines that contain zero or multiple known image identifier tokens

- [ ] **Step 4: Write failing command-runner test**

Create a script that emits 100 KiB to stdout and exits `7` after writing
`failure` to stderr. Assert:

```swift
let output = try runner.run(
    executable: script,
    arguments: ["one", "two"],
    environment: [:]
)
XCTAssertEqual(output.exitCode, 7)
XCTAssertEqual(output.stderr, "failure\n")
XCTAssertGreaterThan(output.stdout.utf8.count, 100_000)
```

This guards against pipe-buffer deadlock.

- [ ] **Step 5: Implement command runner with temporary output files**

Define:

```swift
public struct CleanupCommandOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public protocol CleanupCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> CleanupCommandOutput
}

public struct ProcessCleanupCommandRunner: CleanupCommandRunning {
    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> CleanupCommandOutput
}
```

Use two `mkstemp`-backed files for stdout/stderr, pass their file handles to
`Process`, wait, then read. Remove only those exact temporary files in `defer`.
Map signal termination to `128 + signal`.

- [ ] **Step 6: Write failing provider command-sequence test**

With `RecordingCleanupCommandRunner`, assert `ProcessCleanupInventoryProvider`
runs exactly:

```text
/usr/bin/xcrun simctl list devices -j
/usr/bin/xcrun simctl runtime list -j
/usr/bin/xcrun simctl runtime delete --outdated --dry-run
/bin/ps -axo command=
```

Assert every xcrun environment contains `SIMLEASE_HELD=1`.

- [ ] **Step 7: Implement inventory provider**

Define:

```swift
public protocol CleanupInventoryProviding: Sendable {
    func inventory() throws -> CleanupInventory
    func deleteDevice(id: String) throws
    func deleteRuntime(id: String) throws
}

public final class ProcessCleanupInventoryProvider:
    CleanupInventoryProviding,
    @unchecked Sendable
{
    public init(
        runner: any CleanupCommandRunning = ProcessCleanupCommandRunner(),
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        psURL: URL = URL(fileURLWithPath: "/bin/ps"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        capacityURL: URL = FileManager.default.homeDirectoryForCurrentUser
    )
}
```

`inventory()` fails if any required command exits nonzero. Active tests are
process-list lines containing `xcodebuild` and one of:

```text
 test
 test-without-building
 build-for-testing
```

Deletion methods run only:

```text
xcrun simctl delete <device-UUID>
xcrun simctl runtime delete <runtime-image-ID>
```

Any nonzero exit throws `CleanupInventoryError.commandFailed`.

Under `#if DEBUG || SIMLEASE_TESTING`, the production factory must honor
`SIMLEASE_XCRUN_PATH` and `SIMLEASE_PS_PATH`. Release builds ignore them.

- [ ] **Step 8: Run Task 2 tests**

Run:

```bash
swift test --filter CleanupInventoryTests
swift test --filter CleanupCommandRunnerTests
```

Expected: all selected tests pass.

- [ ] **Step 9: Conditional commit checkpoint**

If commits are authorized and base implementation is committed:

```bash
git add Sources/SimLeaseCore/CleanupInventory.swift \
  Sources/SimLeaseCore/CleanupCommandRunner.swift \
  Tests/SimLeaseCoreTests/CleanupInventoryTests.swift \
  Tests/SimLeaseCoreTests/CleanupCommandRunnerTests.swift
git commit -m "feat: inventory simulator storage"
```

Otherwise leave files unstaged.

---

### Task 3: Eligibility planning and protected reasons

**Files:**
- Create: `Sources/SimLeaseCore/CleanupPlanner.swift`
- Create: `Tests/SimLeaseCoreTests/CleanupPlannerTests.swift`

**Interfaces:**
- Consumes: `CleanupInventory`, `CleanupPlan`, `CleanupReview`
- Produces: `CleanupPlanner.makeReview(inventory:now:id:)`

- [ ] **Step 1: Write failing 30-day boundary tests**

Use `now = Date(timeIntervalSince1970: 3_000_000)` and:

```swift
let exactlyThirtyDays = now.addingTimeInterval(-30 * 24 * 60 * 60)
let newer = exactlyThirtyDays.addingTimeInterval(1)
```

Assert exactly 30 days is eligible and one second newer is protected with
`.notOldEnough`.

- [ ] **Step 2: Write failing safety-rule tests**

Cover exact expectations:

- `Booted` device -> `.booted`
- missing `lastUsedAt` -> `.missingLastUsedAt`
- `dataPath` outside
  `~/Library/Developer/CoreSimulator/Devices/<UUID>/data` ->
  `.invalidDataPath`
- global active test -> every candidate `.activeTests`
- runtime absent from dry-run IDs -> `.notOutdated`
- runtime used by a booted device -> `.bootedRuntime`
- missing size does not block an otherwise eligible target
- no eligible target -> `review.plan == nil`
- known sizes sum; unknown sizes contribute zero

- [ ] **Step 3: Run planner tests and verify failure**

Run:

```bash
swift test --filter CleanupPlannerTests
```

Expected: compile failure because `CleanupPlanner` does not exist.

- [ ] **Step 4: Implement pure planner**

Define:

```swift
public struct CleanupPlanner: Sendable {
    public let devicesRoot: URL
    public let staleAge: TimeInterval
    public let planLifetime: TimeInterval

    public init(
        devicesRoot: URL,
        staleAge: TimeInterval = 30 * 24 * 60 * 60,
        planLifetime: TimeInterval = 10 * 60
    )

    public func makeReview(
        inventory: CleanupInventory,
        now: Date,
        id: String
    ) -> CleanupReview
}
```

Sort eligible and protected devices by oldest known `lastUsedAt`, then name.
Sort runtimes by runtime identifier, build, then image identifier. This keeps
CLI/menu output deterministic.

Path validation must compare standardized path components, not string prefix.
Exact allowed data path:

```text
<devicesRoot>/<UUID>/data
```

If no eligible targets remain, return:

```swift
CleanupReview(
    plan: nil,
    protected: protected,
    estimatedBytes: 0
)
```

- [ ] **Step 5: Run planner tests**

Run:

```bash
swift test --filter CleanupPlannerTests
```

Expected: all selected tests pass.

- [ ] **Step 6: Conditional commit checkpoint**

If commits are authorized and base implementation is committed:

```bash
git add Sources/SimLeaseCore/CleanupPlanner.swift \
  Tests/SimLeaseCoreTests/CleanupPlannerTests.swift
git commit -m "feat: plan protected simulator cleanup"
```

Otherwise leave files unstaged.

---

### Task 4: Atomic plan store, integrity, and one-time consumption

**Files:**
- Create: `Sources/SimLeaseCore/CleanupPlanStore.swift`
- Create: `Tests/SimLeaseCoreTests/CleanupPlanStoreTests.swift`

**Interfaces:**
- Consumes: `LeasePaths.cleanupPlans`, `CleanupPlan`, `JSONEncoder.simLease`
- Produces: `CleanupPlanStore.save(_:)`, `consume(id:now:)`, `prune(now:)`

- [ ] **Step 1: Write failing storage tests**

Verify:

```swift
try store.save(plan)
XCTAssertEqual(try store.consume(id: "ABC123", now: validDate), plan)
XCTAssertThrowsError(
    try store.consume(id: "ABC123", now: validDate)
) {
    XCTAssertEqual($0 as? CleanupPlanStoreError, .missing)
}
```

Also verify:

- plan directory mode `0700`
- plan file mode `0600`
- lowercase, punctuation, and wrong-length IDs reject as `.invalidID`
- expired plan rejects as `.expired` and is consumed
- changed plan payload rejects as `.invalidIntegrity` and is consumed
- `prune(now:)` removes only plan files older than 24 hours
- unrelated files in the cache root remain

- [ ] **Step 2: Run store tests and verify failure**

Run:

```bash
swift test --filter CleanupPlanStoreTests
```

Expected: compile failure because `CleanupPlanStore` does not exist.

- [ ] **Step 3: Implement canonical plan envelope**

Define:

```swift
private struct StoredCleanupPlan: Codable {
    let plan: CleanupPlan
    let digest: String
}

public enum CleanupPlanStoreError: Error, Equatable {
    case invalidID
    case alreadyExists
    case missing
    case expired
    case invalidIntegrity
}

public final class CleanupPlanStore: @unchecked Sendable {
    public init(paths: LeasePaths, fileManager: FileManager = .default) throws
    public func save(_ plan: CleanupPlan) throws
    public func consume(id: String, now: Date) throws -> CleanupPlan
    public func prune(now: Date) throws
}
```

ID validation regex semantics:

```text
^[A-Z0-9]{6}$
```

Canonical digest is uppercase hex SHA-256 over
`JSONEncoder.simLease.encode(plan)`. Read and validate before removal, but use
`defer` so every existing plan file is removed after one consume attempt.
Writes use the same temporary-file, `fsync`, rename, and permission pattern as
`MetadataStore`.

- [ ] **Step 4: Run store tests**

Run:

```bash
swift test --filter CleanupPlanStoreTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Conditional commit checkpoint**

If commits are authorized and base implementation is committed:

```bash
git add Sources/SimLeaseCore/CleanupPlanStore.swift \
  Tests/SimLeaseCoreTests/CleanupPlanStoreTests.swift
git commit -m "feat: persist one-time cleanup plans"
```

Otherwise leave files unstaged.

---

### Task 5: Revalidating executor and cleanup service

**Files:**
- Create: `Sources/SimLeaseCore/CleanupExecutor.swift`
- Create: `Sources/SimLeaseCore/CleanupService.swift`
- Create: `Tests/SimLeaseCoreTests/CleanupExecutorTests.swift`
- Create: `Tests/SimLeaseCoreTests/CleanupServiceTests.swift`

**Interfaces:**
- Consumes: `LeaseCoordinator.tryAcquire`, `CleanupInventoryProviding`, `CleanupPlanner`, `CleanupPlanStore`
- Produces: `CleanupServicing.createPlan()`, `apply(planID:)`, typed cleanup errors

- [ ] **Step 1: Write failing executor ordering test**

Use a sequence provider whose inventories remain eligible and record calls.
Apply a plan containing two devices and one runtime. Assert:

```swift
XCTAssertEqual(provider.calls, [
    .inventory,
    .inventory,
    .deleteDevice("DEVICE-1"),
    .inventory,
    .deleteDevice("DEVICE-2"),
    .inventory,
    .inventory,
    .deleteRuntime("RUNTIME-1"),
    .inventory,
])
```

The first inventory is global revalidation. Every delete has an immediately
preceding target inventory. Runtime phase performs an extra refreshed
inventory/dry-run before its first target. Final inventory supplies measured
available capacity.

- [ ] **Step 2: Write failing drift and failure tests**

Verify:

- device becomes `Booted` -> skipped, no delete call
- device disappears -> skipped
- new candidate appears -> ignored
- runtime leaves outdated dry-run set -> skipped
- booted device appears on runtime -> runtime skipped
- active tests appear -> every remaining target skipped
- device delete returns `Invalid device` -> refresh and record skipped
- other delete error -> failed
- inventory failure after device failure -> all runtime targets skipped
- any skip/failure makes `CleanupResult.isPartial == true`
- free-space result uses first and last inventories, not target-size arithmetic

- [ ] **Step 3: Run executor tests and verify failure**

Run:

```bash
swift test --filter CleanupExecutorTests
```

Expected: compile failure because `CleanupExecutor` does not exist.

- [ ] **Step 4: Implement executor**

Define:

```swift
public final class CleanupExecutor: @unchecked Sendable {
    public init(
        provider: any CleanupInventoryProviding,
        planner: CleanupPlanner
    )

    public func apply(plan: CleanupPlan, now: Date) throws -> CleanupResult
}
```

Use planner eligibility on every refreshed inventory, then match only by
`kind + identifier`. Never construct a delete command from refreshed targets
that were absent from the stored plan.

Classify command errors containing literal `Invalid device` as skipped after
one refresh. Do not retry deletion.

- [ ] **Step 5: Write failing service tests**

Define a fake coordinator holder and assert:

```swift
XCTAssertThrowsError(try service.createPlan()) {
    guard case CleanupServiceError.leaseBusy(let status) = $0 else {
        return XCTFail("Expected busy status")
    }
    XCTAssertEqual(status.state, .leased)
}
```

Also test:

- empty review is returned without `store.save`
- six-character generator collision retries
- create saves non-empty plan
- apply consumes before executor runs
- expired/integrity store errors map without invoking executor
- service releases lease after success and every thrown error

- [ ] **Step 6: Implement service**

Define:

```swift
public protocol CleanupServicing: Sendable {
    func createPlan() throws -> CleanupReview
    func apply(planID: String) throws -> CleanupResult
}

public enum CleanupServiceError: Error {
    case leaseBusy(LeaseStatus)
    case plan(CleanupPlanStoreError)
    case inventory(CleanupInventoryError)
}

public final class CleanupService: CleanupServicing, @unchecked Sendable {
    public init(
        coordinator: LeaseCoordinator,
        identity: LeaseIdentity,
        provider: any CleanupInventoryProviding,
        planner: CleanupPlanner,
        store: CleanupPlanStore,
        executor: CleanupExecutor,
        now: @escaping @Sendable () -> Date = Date.init,
        idGenerator: @escaping @Sendable () -> String
    )

    public func createPlan() throws -> CleanupReview
    public func apply(planID: String) throws -> CleanupResult
}
```

Production ID generation uses six characters from:

```text
ABCDEFGHJKLMNPQRSTUVWXYZ23456789
```

This avoids ambiguous `0/O` and `1/I`.

Both methods:

1. call `tryAcquire`
2. if nil, read status and throw `.leaseBusy`
3. keep the returned handle alive for the full operation
4. release in `defer`

- [ ] **Step 7: Run Task 5 tests**

Run:

```bash
swift test --filter CleanupExecutorTests
swift test --filter CleanupServiceTests
```

Expected: all selected tests pass.

- [ ] **Step 8: Conditional commit checkpoint**

If commits are authorized and base implementation is committed:

```bash
git add Sources/SimLeaseCore/CleanupExecutor.swift \
  Sources/SimLeaseCore/CleanupService.swift \
  Tests/SimLeaseCoreTests/CleanupExecutorTests.swift \
  Tests/SimLeaseCoreTests/CleanupServiceTests.swift
git commit -m "feat: revalidate simulator cleanup plans"
```

Otherwise leave files unstaged.

---

### Task 6: CLI plan and apply commands

**Files:**
- Modify: `Sources/SimLeaseCLI/CommandParser.swift`
- Modify: `Sources/SimLeaseCLI/CLI.swift`
- Create: `Sources/SimLeaseCLI/CleanupFormatting.swift`
- Modify: `Tests/SimLeaseCLITests/CommandParserTests.swift`
- Create: `Tests/SimLeaseCLITests/CleanupCLITests.swift`

**Interfaces:**
- Consumes: `CleanupServicing`, `CleanupReview`, `CleanupResult`
- Produces: `simlease clean plan [--json]`, `simlease clean apply <ID> [--json]`

- [ ] **Step 1: Write failing parser tests**

Assert:

```swift
XCTAssertEqual(
    try CommandParser.parse(["simlease", "clean", "plan"]),
    .cleanPlan(json: false)
)
XCTAssertEqual(
    try CommandParser.parse(["simlease", "clean", "plan", "--json"]),
    .cleanPlan(json: true)
)
XCTAssertEqual(
    try CommandParser.parse(["simlease", "clean", "apply", "ABC123", "--json"]),
    .cleanApply(id: "ABC123", json: true)
)
```

Reject:

```text
simlease clean
simlease clean plan --apply
simlease clean apply
simlease clean apply ABC123 --yes
simlease clean apply device-uuid
```

- [ ] **Step 2: Run parser tests and verify failure**

Run:

```bash
swift test --filter CommandParserTests
```

Expected: compile failure because clean cases do not exist.

- [ ] **Step 3: Implement parser cases**

Add:

```swift
case cleanPlan(json: Bool)
case cleanApply(id: String, json: Bool)
```

Parser validates confirmation ID before returning `.cleanApply`.

- [ ] **Step 4: Write failing CLI output tests**

Inject a `CleanupServiceStub` through:

```swift
CLIConfiguration(
    paths: paths,
    timing: timing,
    standardOutput: output,
    standardError: errors,
    cleanupService: stub
)
```

Verify:

- plan JSON decodes as `CleanupReview`
- apply JSON decodes as `CleanupResult`
- human plan groups `Devices`, `Runtimes`, `Protected`, estimate, ID, expiry
- empty plan prints `No stale simulator storage is eligible`
- partial result returns `76`
- missing/expired/integrity plan returns `73`
- busy lease returns `75` and prints current owner
- invalid inventory returns `74`
- usage text becomes `Usage: simlease <status|name|hold|clean>`

- [ ] **Step 5: Implement CLI service construction and formatting**

Add optional configuration dependency:

```swift
public let cleanupService: (any CleanupServicing)?
```

Default is `nil`; existing call sites remain source-compatible.

Production construction uses:

- current `LeasePaths`
- `MetadataStore`
- `LeaseCoordinator`
- `LeaseIdentity.resolve`
- `ProcessCleanupInventoryProvider`
- `CleanupPlanner` rooted at
  `~/Library/Developer/CoreSimulator/Devices`
- `CleanupPlanStore`
- `CleanupExecutor`

`CleanupFormatting` must use `ByteCountFormatter` with `.file` style, and print
`Unknown` for nil size. JSON always uses `JSONEncoder.simLease`.

Catch typed errors before the general catch and return exact codes from the
spec.

- [ ] **Step 6: Run CLI tests**

Run:

```bash
swift test --filter CommandParserTests
swift test --filter CleanupCLITests
swift test --filter SimLeaseCLITests
```

Expected: all selected tests pass.

- [ ] **Step 7: Conditional commit checkpoint**

If commits are authorized and base implementation is committed:

```bash
git add Sources/SimLeaseCLI/CommandParser.swift \
  Sources/SimLeaseCLI/CLI.swift \
  Sources/SimLeaseCLI/CleanupFormatting.swift \
  Tests/SimLeaseCLITests/CommandParserTests.swift \
  Tests/SimLeaseCLITests/CleanupCLITests.swift
git commit -m "feat: add simulator cleanup CLI"
```

Otherwise leave files unstaged.

---

### Task 7: Menu cleanup review and confirmation

**Files:**
- Create: `Sources/SimLeaseMenuCore/MenuCleanupProvider.swift`
- Create: `Sources/SimLeaseMenuCore/CleanupViewModel.swift`
- Create: `Sources/SimLeaseMenuBar/CleanupReviewView.swift`
- Modify: `Sources/SimLeaseMenuBar/LeasePopoverView.swift`
- Modify: `Sources/SimLeaseMenuBar/SimLeaseMenuBarApp.swift`
- Create: `Tests/SimLeaseMenuBarTests/CleanupViewModelTests.swift`

**Interfaces:**
- Consumes: bundled `simlease`, `CleanupReview`, `CleanupResult`
- Produces: `MenuCleanupProviding`, `CleanupViewModel`, `Review Cleanup…` window

- [ ] **Step 1: Write failing cleanup view-model tests**

Define state:

```swift
public enum CleanupViewState: Equatable, Sendable {
    case idle
    case loading
    case review(CleanupReview)
    case applying(CleanupReview)
    case result(CleanupResult)
    case error(String)
}
```

Tests verify:

```swift
let model = CleanupViewModel(provider: stub)
await model.load()
XCTAssertEqual(model.state, .review(review))
XCTAssertFalse(model.canApply)
model.confirmationText = "ABC123"
XCTAssertTrue(model.canApply)
await model.apply()
XCTAssertEqual(model.state, .result(result))
```

Also verify:

- wrong-case ID does not enable Apply
- empty review never enables Apply
- loading error preserves exact localized message
- apply error returns to review with error text
- a status refresh on `MenuViewModel` never calls cleanup provider

- [ ] **Step 2: Run view-model tests and verify failure**

Run:

```bash
swift test --filter CleanupViewModelTests
```

Expected: compile failure because cleanup menu types do not exist.

- [ ] **Step 3: Implement CLI-backed menu provider**

Define:

```swift
public protocol MenuCleanupProviding: Sendable {
    func plan() async throws -> CleanupReview
    func apply(id: String) async throws -> CleanupResult
}

public actor CLICleanupProvider: MenuCleanupProviding {
    public init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    )
}
```

Resolve executable using the same order as `CLIStatusProvider`:

1. DEBUG `SIMLEASE_EXECUTABLE_PATH`
2. bundled `Contents/Resources/bin/simlease`
3. `~/.local/lib/simlease/simlease`

Run only:

```text
simlease clean plan --json
simlease clean apply <ID> --json
```

Plan requires exit `0`. Apply accepts exit `0` or `76` when stdout decodes as
`CleanupResult`. Other nonzero exits throw an error containing exact stderr.

- [ ] **Step 4: Implement cleanup view model**

Define:

```swift
@MainActor
public final class CleanupViewModel: ObservableObject {
    @Published public private(set) var state: CleanupViewState = .idle
    @Published public var confirmationText = ""
    @Published public private(set) var error: String?

    public init(provider: any MenuCleanupProviding)
    public func load() async
    public func apply() async
    public var canApply: Bool { get }
}
```

`canApply` requires a nonempty plan and exact case-sensitive ID match.

- [ ] **Step 5: Implement native review window**

Add a second scene:

```swift
Window("Simulator Cleanup", id: "cleanup") {
    CleanupReviewView(viewModel: cleanupViewModel)
}
.defaultSize(width: 560, height: 520)
```

`LeasePopoverView` gains:

```swift
Button("Review Cleanup…") {
    openWindow(id: "cleanup")
}
```

This button only opens the window. `CleanupReviewView.task` calls `load()`.

Window content order:

1. `Simulator Cleanup` title
2. known-size estimate
3. Devices disclosure section
4. Runtimes disclosure section
5. Protected disclosure section
6. confirmation ID
7. exact-match text field
8. `Cancel` and `Apply Cleanup`

Apply button uses `.borderedProminent`, disabled unless `canApply`. Results
group Deleted, Skipped, Failed and show measured free-space change. Use
`ScrollView` for target lists. Do not add scheduling, selection, force release,
or cleanup on app launch.

- [ ] **Step 6: Add DEBUG fixtures**

Support:

```text
SIMLEASE_CLEANUP_PREVIEW_STATE=empty
SIMLEASE_CLEANUP_PREVIEW_STATE=review
SIMLEASE_CLEANUP_PREVIEW_STATE=partial
SIMLEASE_CLEANUP_PREVIEW_STATE=error
```

Release builds ignore the variable. Review fixture includes:

- 3 devices
- 2 runtimes
- 5 protected targets
- one unknown size
- one long target name

- [ ] **Step 7: Build and run menu tests**

Run:

```bash
swift test --filter CleanupViewModelTests
swift test --filter SimLeaseMenuBarTests
swift build --product SimLeaseMenuBar
```

Expected: all selected tests and build pass.

- [ ] **Step 8: Conditional commit checkpoint**

If commits are authorized and base implementation is committed:

```bash
git add Sources/SimLeaseMenuCore/MenuCleanupProvider.swift \
  Sources/SimLeaseMenuCore/CleanupViewModel.swift \
  Sources/SimLeaseMenuBar/CleanupReviewView.swift \
  Sources/SimLeaseMenuBar/LeasePopoverView.swift \
  Sources/SimLeaseMenuBar/SimLeaseMenuBarApp.swift \
  Tests/SimLeaseMenuBarTests/CleanupViewModelTests.swift
git commit -m "feat: review simulator cleanup in menu bar"
```

Otherwise leave files unstaged.

---

### Task 8: Fake end-to-end smoke, packaging, and read-only live plan

**Files:**
- Create: `Tests/SmokeTests/cleanup-smoke.zsh`
- Modify: `README.md`
- Modify: `Tests/InstallationTests/package-app.zsh`

**Interfaces:**
- Consumes: installed CLI/menu bundle, DEBUG executable overrides
- Produces: deterministic no-real-deletion smoke and user-visible verification instructions

- [ ] **Step 1: Write fake cleanup smoke**

`cleanup-smoke.zsh` creates a temporary cache, fake `xcrun`, fake `ps`, and
fake device state. It must:

1. compile with `-D SIMLEASE_TESTING`
2. make plan with one stale shutdown device, one booted device, one recent
   device, and one outdated runtime
3. verify plan JSON includes only stale device and outdated runtime
4. verify protected reasons for booted and recent devices
5. apply wrong ID and get `73` without delete log
6. apply exact ID
7. verify delete log order:

```text
simctl delete DEVICE-STALE
simctl runtime delete RUNTIME-OUTDATED
```

8. verify second apply gets `73`
9. verify final result separates deleted/skipped/failed
10. verify fake state only changed for exact planned targets

The fake `xcrun` must fail the smoke if it receives:

```text
simctl delete all
simctl delete unavailable
simctl runtime delete --outdated
simctl runtime delete --unusable
```

- [ ] **Step 2: Run fake smoke and fix only implementation-owned failures**

Run:

```bash
swift build -c debug -Xswiftc -DSIMLEASE_TESTING
zsh Tests/SmokeTests/cleanup-smoke.zsh
```

Expected: `cleanup-smoke: PASS`.

- [ ] **Step 3: Update packaging assertion**

Extend `package-app.zsh` to assert bundled CLI supports:

```bash
"$app/Contents/Resources/bin/simlease" clean plan --help
```

Capture usage without invoking `simctl`:

```bash
usage_file="$(mktemp)"
if "$app/Contents/Resources/bin/simlease" clean 2>"$usage_file"; then
  fail "incomplete clean command unexpectedly succeeded"
fi
grep -q 'status|name|hold|clean' "$usage_file" \
  || fail "bundled CLI usage omits clean"
rm "$usage_file"
```

- [ ] **Step 4: Update README**

Document:

```sh
simlease clean plan
simlease clean plan --json
simlease clean apply ABC123
```

State:

- 30-day device rule
- Apple-outdated runtime rule
- booted and unknown-age protection
- 10-minute one-time plan
- exact confirmation requirement
- menu review workflow
- no automatic cleanup
- estimated versus measured space
- real deletion requires reviewing exact targets

- [ ] **Step 5: Run complete automated gate**

Run:

```bash
swift test
zsh Tests/InstallationTests/install-cli.zsh
zsh Tests/InstallationTests/package-app.zsh
zsh Tests/InstallationTests/install-app.zsh
zsh Tests/SmokeTests/menu-owner-smoke.zsh
zsh Tests/SmokeTests/cleanup-smoke.zsh
git diff --check
```

Expected: all commands exit `0`.

- [ ] **Step 6: Package and install updated app**

Run:

```bash
scripts/package-app.sh
scripts/install.sh
codesign --verify --deep --strict "$HOME/Applications/SimLease.app"
launchctl print "gui/$(id -u)/com.jdelaire.simlease"
```

Expected: signed app installed, LaunchAgent running, custom AXe still reports
`d45fd82`.

- [ ] **Step 7: Run read-only live planning**

Run only:

```bash
simlease clean plan --json
xcrun simctl runtime delete --outdated --dry-run
```

Verify:

- booted devices are protected
- devices with unknown/recent `lastUsedAt` are protected
- eligible device UUIDs match current `simctl list devices -j`
- eligible runtime IDs match current Apple dry-run
- estimated size is reported separately from current free space

Do not run `simlease clean apply`.

- [ ] **Step 8: Present exact live plan for separate approval**

Report:

- every eligible device name, UUID, last-use date, and size
- every eligible runtime identifier, version/build, and size
- all booted targets and protected reasons
- estimated recovery
- plan expiry

Ask for explicit approval of that exact confirmation ID. Stop without deleting
if approval is absent or plan expires.

- [ ] **Step 9: Conditional commit checkpoint**

If commits are authorized and base implementation is committed:

```bash
git add Tests/SmokeTests/cleanup-smoke.zsh \
  Tests/InstallationTests/package-app.zsh \
  README.md
git commit -m "test: verify stale simulator cleanup"
```

Otherwise leave files unstaged.

---

## Completion Gate

Implementation is ready for live cleanup review only when:

- all Swift tests pass
- install/package/menu-owner/cleanup smoke scripts pass
- app signature and LaunchAgent are valid
- custom AXe remains preserved
- DEBUG fake execution proves exact device-before-runtime deletion
- menu review/confirmation states receive human visual validation
- live plan matches current `simctl` inventory and Apple runtime dry-run
- no real cleanup apply command has run without separate exact approval
