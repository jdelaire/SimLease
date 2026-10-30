# Simulator Resources, Slim Profiles and Device Data Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure per-simulator memory and CPU, let projects opt devices into slim launchd profiles, and reclaim per-device caches and logs through Storage Cleanup.

**Architecture:** A libproc-based sampler feeds `SimulatorUsage` and a new `measure` command. A ported service catalog plus `SimulatorSlimService` converges a shut-down device's launchd disabled set under an exclusive lease, journaled through the existing `device-recovery.json` gate. Storage Cleanup gains a `deviceData` target kind revalidated at apply time.

**Tech Stack:** Swift 6, SwiftPM, XCTest, Darwin libproc, `xcrun simctl`.

**Spec:** `docs/superpowers/specs/2026-10-30-simulator-resources-and-slimming-design.md`

## Global Constraints

- macOS 15+, Apple Silicon. No new package dependencies.
- No code comments. Test only meaningful logic.
- Host headroom remains the only lane admission input.
- Slim: iOS runtimes 18.5 or newer only; device must be `Shutdown`, available, unpaired, not crash-blocked.
- Slim never disables `com.apple.SpringBoard`, `com.apple.backboardd` or any always-enabled label.
- Up to 8 concurrent launchctl spawns, up to 3 passes, pauses 1 s then 2 s.
- `status --devices` samples only when a listed device is `Booted`; CPU uses `resource-sample.json` when 0.2 to 30 s old, else a second sample 500 ms later.
- `measure` default limit 15.
- Device data cleanup deletes only children of target directories, never the directories, never resolving symlinks; device data targets take the simulator lease.
- Keep simslim's MIT notice for the ported catalog in `NOTICE`.
- One commit per feature on `main`.

## Review Focus

- Simulator in a non-default device set (XCTest clones under `XCTestDevices`): root detection keys on the UUID path segment, not the set path. Test in Task 1.
- PID reuse between the two CPU snapshots: a PID whose start differs between snapshots contributes no CPU delta. Test in Task 1.
- Slim interrupted after boot: rerun with `--settled` converges and leaves the device `Shutdown`; without `--settled` it refuses. Test in Task 4.
- A `device repair` against a pending slim transaction refuses instead of running repair logic. Test in Task 4.
- A `Caches` directory under `Documents` or inside the app bundle is never selected, and a symlinked `tmp` pointing outside the data path is skipped. Test in Task 6.

---

### Task 1: Resource sampler

**Files:**
- Create: `Sources/SimLeaseCore/SimulatorResources.swift`
- Create: `Sources/SimLeaseCore/SystemSimulatorResourceSampler.swift`
- Test: `Tests/SimLeaseCoreTests/SimulatorResourcesTests.swift`

**Interfaces:**
- Produces:
  - `struct SimulatorProcessSample: Equatable, Sendable { pid: Int32; parentPID: Int32; name: String; startMicroseconds: UInt64; footprintBytes: UInt64; cpuNanoseconds: UInt64 }`
  - `struct SimulatorResourceSnapshot: Equatable, Sendable { takenAtNanoseconds: UInt64; roots: [String: Int32]; processes: [Int32: SimulatorProcessSample] }`
  - `struct SimulatorResourceUsage: Codable, Equatable, Sendable { memoryBytes: UInt64; processCount: Int; cpuPercent: Double? }`
  - `struct SimulatorResourceCache: Sendable { init(paths: LeasePaths); func read() -> SimulatorResourceSnapshot?; func write(_ snapshot: SimulatorResourceSnapshot) }` at `resource-sample.json`; codable snapshot.
  - `enum SimulatorResources { static func deviceID(launchdArguments: [String]) -> String?; static func measure(_ first: SimulatorResourceSnapshot, _ second: SimulatorResourceSnapshot?) -> [String: SimulatorResourceUsage]; static func processes(deviceID: String, in snapshot: SimulatorResourceSnapshot) -> [SimulatorProcessSample] }` (processes sorted by footprint descending, then PID)
  - `protocol SimulatorResourceSampling: Sendable { func snapshot() throws -> SimulatorResourceSnapshot }`
  - `struct SystemSimulatorResourceSampler: SimulatorResourceSampling`

- [ ] **Step 1: Write failing tests**
  - `testDeviceIDFromBootstrapArgument`: `["launchd_sim", "/Users/a/Library/Developer/XCTestDevices/5855AB2E-0078-4A4B-9149-780B23A0AA1C/data/var/run/launchd_bootstrap.plist"]` returns `"5855AB2E-0078-4A4B-9149-780B23A0AA1C"`; lowercase UUID returns uppercased; arguments without the bootstrap suffix return nil.
  - `testMeasureSumsDescendantsOnly`: root 10 with children 11, 12 and grandchild 13; unrelated 20. Footprints 100/200/300/400/999. Expect `memoryBytes == 1000`, `processCount == 4`, `cpuPercent == nil` without a second snapshot.
  - `testCPUPercentUsesDeltasOfSurvivingProcesses`: second snapshot 500_000_000 ns later; PID 10 +250_000_000 ns, PID 11 +500_000_000 ns, PID 12 missing in second, PID 13 same PID but different `startMicroseconds`. Expect `cpuPercent == 150`.
  - `testUnreadableRootYieldsNoMeasurement`: root PID not in `processes` returns no entry for that device.
- [ ] **Step 2: Run** `swift test --filter SimulatorResourcesTests`; expect compile failure.
- [ ] **Step 3: Implement** `SimulatorResources` (pure) and `SystemSimulatorResourceSampler`: `proc_listpids(PROC_UID_ONLY, getuid())`, `ProcessReference.info(pid:)` for ppid/name/start, `proc_pid_rusage(pid, RUSAGE_INFO_V4)` for `ri_phys_footprint`, `ri_user_time + ri_system_time` converted with `mach_timebase_info`, `mach_continuous_time` converted for `takenAtNanoseconds`. Roots: processes named `launchd_sim` whose `KERN_PROCARGS2` arguments (via `SystemSimulatorProcessReader.parseArguments`) yield a device ID. Build the parent map from BSD info for all PIDs; call `proc_pid_rusage` only for descendants of roots. Unreadable processes are skipped.
- [ ] **Step 4: Run** `swift test --filter SimulatorResourcesTests`; expect PASS.

### Task 2: Status, measure and menu surfaces

**Files:**
- Modify: `Sources/SimLeaseCore/SimulatorUsage.swift`
- Modify: `Sources/SimLeaseCLI/CommandParser.swift`, `Sources/SimLeaseCLI/CLI.swift`
- Modify: `Sources/SimLeaseMenuCore/MenuDisplayState.swift`, `Sources/SimLeaseMenuBar/LeasePopoverView.swift`
- Modify: `README.md`
- Test: `Tests/SimLeaseCoreTests/SimulatorUsageTests.swift`, `Tests/SimLeaseCLITests/CommandParserTests.swift`, `Tests/SimLeaseMenuBarTests/MenuDisplayStateTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `SimulatorUsage` optional `memoryBytes: UInt64?`, `processCount: Int?`, `cpuPercent: Double?`, with `func withResources(_ usage: SimulatorResourceUsage?) -> SimulatorUsage`.
  - `ParsedCommand.measure(deviceID: String, json: Bool, limit: Int)`.
  - `DeviceDisplayItem.resources: String?` formatted `"1.2 GB · 34% CPU"` (CPU part omitted when nil); `ByteCountFormatter` memory style.
  - `CLIConfiguration.resourceSampler: (any SimulatorResourceSampling)?` (nil means system sampler).

- [ ] **Step 1: Write failing tests**
  - Parser: `measure --device UUID` gives limit 15, json false; `--limit 5 --json` parsed; limit 0 and missing device are usage errors.
  - `SimulatorUsage` JSON round trip omits resource keys when nil.
  - Menu: a booted device with `memoryBytes: 1_288_490_189, cpuPercent: 34.4` shows `resources == "1.2 GB · 34% CPU"`; a shutdown device shows nil.
- [ ] **Step 2: Run** the three filters; expect failures.
- [ ] **Step 3: Implement.** In `runStatus` after `usage` is built: if any usage is `Booted`, take a snapshot; use the cached snapshot as `first` when 0.2 to 30 s old, else sleep 0.5 s and take another; write the latest to the cache; `SimulatorResources.measure`, map `withResources`. Sampling errors leave fields nil. Text line appends `, 1.2 GB, 34% CPU, 70 processes` when present. `runMeasure`: device must be in one snapshot's roots else exit 74 with `SimLease: simulator UUID is not booted`; text prints total line then `PID  MEMORY  CPU%  NAME` rows; JSON `{deviceID, usage, processes:[{pid,name,memoryBytes,cpuPercent}]}`. Add `measure` to the usage string. Popover phone card renders `resources` under the detail line. README: document `measure` and the new status fields.
- [ ] **Step 4: Run** `swift test`; expect PASS.
- [ ] **Step 5: Commit** `feat: show per-simulator memory and CPU`.

### Task 3: Service catalog and profile resolution

**Files:**
- Create: `Sources/SimLeaseCore/SimulatorServiceCatalog.swift`
- Create: `NOTICE`
- Test: `Tests/SimLeaseCoreTests/SimulatorServiceCatalogTests.swift`

**Interfaces:**
- Produces:
  - `struct SimulatorServiceCategory: Codable, Equatable, Sendable { id, name, downside: String; approxMemoryMB: Int; labels: [String]; alwaysEnabled: [String] }`
  - `enum SimulatorServiceCatalog { static let categories: [SimulatorServiceCategory]; static let protectedLabels: Set<String>; static var managed: Set<String>; static func desired(keep: Set<String>) throws -> Set<String>; static func delta(current: Set<String>, desired: Set<String>) -> (disable: [String], enable: [String]); static func parseDisabled(_ output: String) -> Set<String>; static func supportsPersistentOverrides(runtime: String) -> Bool }`
  - `enum SimulatorServiceCatalogError: Error { case unknownCategory(String) }`

- [ ] **Step 1: Write failing tests**
  - `desired(keep: [])` excludes `com.apple.SpringBoard`, `com.apple.backboardd`, `com.apple.assistantd`, includes `com.apple.PosterBoard`.
  - `desired(keep: ["widgets"])` excludes `com.apple.navd` even though `connectivity` also lists it.
  - `desired(keep: ["nope"])` throws `unknownCategory("nope")`.
  - `delta` ignores unmanaged disabled labels and returns sorted arrays.
  - `parseDisabled` on `"disabled services = {\n\t\"com.apple.a\" => disabled\n\t\"com.apple.b\" => enabled\n\t\"com.apple.c\" => true\n}"` returns `["com.apple.a", "com.apple.c"]`.
  - Runtime gate: `com.apple.CoreSimulator.SimRuntime.iOS-18-5` true, `iOS-18-4` false, `iOS-27-2` true, `watchOS-11-5` false, malformed false.
- [ ] **Step 2: Run** `swift test --filter SimulatorServiceCatalogTests`; expect failure.
- [ ] **Step 3: Implement.** Port all 15 categories and their labels and always-enabled labels verbatim from simslim `profiles.go` at commit `d594c230`. `NOTICE` carries the simslim MIT copyright and permission text.
- [ ] **Step 4: Run** filter; expect PASS.

### Task 4: Slim service

**Files:**
- Create: `Sources/SimLeaseCore/SimulatorSlimService.swift` (service, `SlimProfileStore`, `SimulatorLaunchdControlling`)
- Modify: `Sources/SimLeaseCore/DeviceRepairService.swift` (`purpose: String?` on `DeviceRepairTransaction`; repair refuses `purpose == "slim"`)
- Modify: `Sources/SimLeaseCore/ProcessSimulatorDeviceManager.swift` (conform to `SimulatorLaunchdControlling`)
- Modify: `Sources/SimLeaseCore/AutomaticRecoveryService.swift:218` (skip PosterBoard when slim profile disables it)
- Test: `Tests/SimLeaseCoreTests/SimulatorSlimServiceTests.swift`

**Interfaces:**
- Consumes: Task 3.
- Produces:
  - `protocol SimulatorLaunchdControlling: Sendable { func launchctl(_ deviceID: String, _ arguments: [String]) throws -> String }`
  - `struct SlimProfile: Codable, Equatable, Sendable { keep: [String]; disabledCount: Int; appliedAt: Date; complete: Bool }`
  - `struct SlimProfileStore: Sendable { init(paths: LeasePaths); func read() throws -> [String: SlimProfile]; func set(_ id: String, _ profile: SlimProfile?) throws }` stored at `slim-profiles.json` under `SharedStateLock`.
  - `struct SlimResult: Codable, Equatable, Sendable { deviceID: String; state: String; disabledCount: Int; keep: [String] }`
  - `struct SimulatorSlimService: Sendable { init(paths:coordinator:identity:devices:launchd:inspect: @escaping @Sendable () throws -> Void, now:, readRetryDelays: [TimeInterval] = [1, 2, 4, 8]); func slim(deviceID: String, keep: Set<String>, settled: Bool) throws -> SlimResult; func unslim(deviceID: String, settled: Bool) throws -> SlimResult }`

- [ ] **Step 1: Write failing tests** with a fake implementing both `SimulatorDeviceManaging` and `SimulatorLaunchdControlling`; overrides show in `print-disabled` immediately, persist across reboot unless `dropOnReboot` is set, and the first N reads after a boot can fail.
  - `testSlimDisablesDesiredLabelsAndRecordsProfile`: result `slimmed`, `disabledCount == desired(keep: []).count`, device `Shutdown`, store entry present, transaction file absent, exactly two boots.
  - `testAlreadySlimDeviceIsUnchangedWithOneBoot`.
  - `testUnslimReenablesManagedOnlyAndRemovesProfile`: an unmanaged disabled label survives.
  - `testLostOverridesFailAndLeaveDeviceShutdown`: fake drops overrides on reboot; throws `failed`, device `Shutdown`, no transaction, no profile.
  - `testRefusesBootedPairedBlockedAndOldRuntime`: four cases, no device commands issued.
  - `testInterruptedSlimRequiresSettledAndConverges`: pre-written slim transaction with a dead owner and the device left `Booted`; without `settled` throws `unsettled`; with `settled` returns `slimmed` and the device ends `Shutdown`.
  - `testPartialFailureLeavesIncompleteProfile`: one label fails all 3 passes; throws, device `Shutdown`, no transaction, profile `complete == false`.
  - `testUnslimAllowedOnCrashBlockedDevice` keeps the block; `slim` on the same device is refused.
  - `testTransientReadFailuresAreRetried`: first two `print-disabled` reads fail, retry delays `[0, 0, 0, 0]`, result `slimmed`.
  - `testLegacyRepairJournalDecodes`: JSON without `purpose` decodes.
  - `testRepairRefusesPendingSlimTransaction` via `DeviceRepairService.repair(deviceID:settled: true)`.
  - In `AutomaticRecoveryTests`: verification of a PosterBoard-triggered block on a device whose complete slim profile disables PosterBoard requires only SpringBoard.
  - `testTransitionsRetryFailedLabels`: fake fails one label's first `disable`; result `slimmed`.
- [ ] **Step 2: Run** `swift test --filter SimulatorSlimServiceTests`; expect failure.
- [ ] **Step 3: Implement** the flow from the spec's "Flow" section. Concurrency via `DispatchQueue.concurrentPerform` over chunks of 8. `ProcessSimulatorDeviceManager.launchctl` runs `simctl spawn ID launchctl …` through the existing `run`.
- [ ] **Step 4: Run** filter and `DeviceRepairTests`; expect PASS.

### Task 5: Slim CLI, status, doctor and menu

**Files:**
- Modify: `Sources/SimLeaseCLI/CommandParser.swift`, `Sources/SimLeaseCLI/CLI.swift`, `Sources/SimLeaseCLI/CoverageDoctor.swift`
- Modify: `Sources/SimLeaseCore/SimulatorUsage.swift` (`slim: SlimProfile?`, populated in `build` via a `slim: [String: SlimProfile]` parameter defaulting to empty)
- Modify: `Sources/SimLeaseMenuCore/MenuDisplayState.swift` (detail prefix `Slim · `)
- Modify: `README.md`
- Test: `Tests/SimLeaseCLITests/CommandParserTests.swift`, `Tests/SimLeaseCLITests/DeviceCLITests.swift`, `Tests/SimLeaseMenuBarTests/MenuDisplayStateTests.swift`

**Interfaces:**
- Consumes: Tasks 3 and 4.
- Produces: `ParsedCommand.deviceSlimList(json: Bool)`, `.deviceSlim(id: String, keep: [String], settled: Bool)`, `.deviceUnslim(id: String, settled: Bool)`.

- [ ] **Step 1: Write failing tests**
  - Parser: `device slim --list`, `device slim --device UUID --keep widgets,health --settled`, `device unslim --device UUID`; `--keep` without `--device`, `--list` with `--device`, empty keep item are usage errors.
  - `device slim --list --json` prints every category id.
  - Menu detail for a device with a slim profile starts with `Slim · `.
- [ ] **Step 2: Run** filters; expect failure.
- [ ] **Step 3: Implement.** `slimService` factory mirrors `deviceService` including the managed-work refusal. Unknown categories exit 64. Doctor JSON adds `slimProfiles: [{deviceID, state: "ok"|"drift"|"missing"|"notBooted", reenabled:[..], extraDisabled:[..]}]`; text prints one line per non-ok entry. README documents slim, unslim, list, the iOS 18.5 floor, the shut-down requirement, `--settled`, and that slimming disables PosterBoard and widgets.
- [ ] **Step 4: Run** `swift test`; expect PASS.
- [ ] **Step 5: Commit** `feat: add opt-in slim simulator profiles`.

### Task 6: Device data cleanup

**Files:**
- Create: `Sources/SimLeaseCore/DeviceDataInventory.swift`
- Modify: `Sources/SimLeaseCore/CleanupModels.swift` (`CleanupTargetKind.deviceData`, `CleanupCategory.simulatorDeviceData`, `CleanupFingerprint.deviceData(path: String, digest: String)`)
- Modify: `Sources/SimLeaseCore/CleanupService.swift:119` (device data targets take the simulator lease)
- Modify: `Sources/SimLeaseCore/CleanupPlanner.swift`, `Sources/SimLeaseCore/CleanupExecutor.swift`, `Sources/SimLeaseCLI/CleanupFormatting.swift`, `Sources/SimLeaseMenuCore/CleanupBreakdown.swift` and any exhaustive switch the compiler flags
- Test: `Tests/SimLeaseCoreTests/DeviceDataInventoryTests.swift`, `Tests/SimLeaseCoreTests/CleanupPlannerTests.swift`, `Tests/SimLeaseCoreTests/CleanupExecutorTests.swift`

**Interfaces:**
- Produces:
  - `enum DeviceDataInventory { static func targets(dataPath: URL) throws -> [URL]; static func measure(_ targets: [URL], dataPath: URL) throws -> (sizeBytes: Int64, digest: String); static func clear(_ targets: [URL], within dataPath: URL) throws }`
  - Planner emits one `deviceData` target per eligible shut-down device, identifier `"device-data:" + UUID`, `path` = data path, fingerprint `.deviceData(path:digest:)`. Placed in `plan.storage`.

- [ ] **Step 1: Write failing tests**
  - Inventory on a temp tree finds `Library/Caches`, `Containers/Data/Application/X/Library/Caches`, `Containers/Data/Application/X/tmp`, `Library/Logs`, `var/db/diagnostics`; skips `Containers/Bundle/Application/Y/Caches`, `Containers/Data/Application/X/Documents/Caches`, `Media/tmp`, and a `tmp` symlink pointing outside the data path.
  - `clear` empties targets and leaves the directories; a child symlink `Caches/link -> ../Documents` is unlinked and `Documents` survives; a target reached through a symlinked intermediate component is refused.
  - `measure` digest changes after a same-size rewrite of a nested file with a new mtime.
  - Planner: shut-down device with data yields a target; booted device yields protection reason `booted`; zero-byte device yields nothing.
  - Executor: device booted at apply is skipped; digest changed is skipped `Target changed since review`; unchanged is cleared.
  - Service: selecting only a device data target while another lane holds the lease defers it with `Simulator lease is in use`.
- [ ] **Step 2: Run** filters; expect failure.
- [ ] **Step 3: Implement.** Executor applies `deviceData` targets after simulator deletions using the current `CleanupInventory` for state and data path, recomputes targets and fingerprint, then `clear` through a `CleanupFileOperator(allowedRoots: [dataPath])`. Formatting label: `Simulator caches & logs`.
- [ ] **Step 4: Run** `swift test`; expect PASS.
- [ ] **Step 5: Commit** `feat: clean simulator caches and logs from storage review`.

### Task 7: Manual verification

- [ ] Build: `swift build -c release`.
- [ ] Create a disposable iOS 18.5+ device with `simlease device create --disposable --name SlimCheck --type … --runtime …`.
- [ ] `simlease run --title "THREAD TITLE" --device UUID -- sh -c 'xcrun simctl boot UUID; xcrun simctl bootstatus UUID; sleep 60; simlease measure --device UUID'` and record memory.
- [ ] `simlease device slim --device UUID`, repeat the measure run, compare.
- [ ] `simlease device unslim --device UUID`; confirm `print-disabled` has no managed labels.
- [ ] `simlease clean plan` lists the device's caches and logs.
