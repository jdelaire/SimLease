# Simulator resources, slim profiles and device cache cleanup

Date: 2026-10-30. Ideas ported from [simslim](https://github.com/MobAI-App/simslim)
(MIT, commit `d594c230`).

## Goal

SimLease opens extra lanes only while the Mac keeps 45% of memory free. A stock
iOS simulator costs about 4 GB of `phys_footprint`; simslim measured 0.9 GB for
the same device with background services disabled. Three changes follow:

1. Show what each booted simulator costs in memory and CPU.
2. Let a project opt a shut-down device into a slim service profile.
3. Reclaim per-device caches, logs and temporary files through Storage Cleanup.

Admission rules do not change. Host headroom still decides when lanes open.

## 1. Per-device resource accounting

### Sampling

`SystemSimulatorResourceSampler` (Core) takes one snapshot of every process
owned by the current user:

- PIDs from `proc_listpids(PROC_UID_ONLY, getuid())`.
- Parent PID, name and start time from `proc_pidinfo(PROC_PIDTBSDINFO)` for
  every PID, to build the parent map.
- `ri_phys_footprint`, `ri_user_time` and `ri_system_time` from
  `proc_pid_rusage(RUSAGE_INFO_V4)`, only for descendants of a simulator root.
  Times are Mach absolute units and are converted with `mach_timebase_info`.
- Roots are processes named `launchd_sim`. Their `KERN_PROCARGS2` arguments
  contain `…/<UUID>/data/var/run/launchd_bootstrap.plist`; the UUID before
  `/data/var/run/launchd_bootstrap.plist` identifies the device.

`SimulatorResources.measure(_ first:, _ second:)` is pure. For each root it
walks descendants through the parent map of the later snapshot and returns
`memoryBytes` (sum of footprints), `processCount` and `cpuPercent`. CPU is the
sum of per-PID CPU time deltas for PIDs present in both snapshots divided by
the wall interval, so it can exceed 100 on multicore Macs. Without a second
snapshot `cpuPercent` is nil. A process that cannot be read is skipped; if the
root itself cannot be read the device has no measurement.

### Surfaces

- `SimulatorUsage` gains optional `memoryBytes`, `processCount` and
  `cpuPercent`. Missing values are omitted from JSON and never shown as 0.
- `status --devices` samples only when at least one listed device is `Booted`.
  It stores per-PID CPU times and the sample time in `resource-sample.json`.
  The next call computes CPU against that file when it is between 0.2 s and
  30 s old; otherwise it takes a second sample 500 ms later. The menu polls
  every 5 s, so steady polling never sleeps.
- A device whose root cannot be read is reported as unavailable, not as
  "not booted". Text output appends `1.2 GB, 34% CPU, 70 processes`.
- The menu phone card detail shows `1.2 GB · 34% CPU` for booted devices.
- New `simlease measure --device UUID [--json] [--limit N]` prints the total
  and the heaviest processes (default 15) sorted by footprint. The device must
  be booted.

## 2. Opt-in slim profiles

### Catalog

`SimulatorServiceCatalog` ports simslim's 15 categories (id, name, downside,
approximate MB, labels, always-enabled exceptions). Rules:

- A label shared by several categories stays enabled when any kept category
  lists it.
- `managed` = every category label plus every always-enabled label.
  Only managed labels are ever enabled or disabled.
- `protected` labels are never disabled: `com.apple.SpringBoard`,
  `com.apple.backboardd`, and every always-enabled label.
- `desired(keep:)` = all category labels minus labels of kept categories minus
  protected labels.

### Runtime gate

Only iOS runtimes 18.5 or newer persist launchd disable overrides across
reboots. Other platforms and older iOS versions are refused. The version is
parsed from the runtime identifier (`…SimRuntime.iOS-18-5`).

### Commands

```
simlease device slim --list [--json]
simlease device slim --device UUID [--keep id,id] [--settled] [--json]
simlease device unslim --device UUID [--settled] [--json]
```

`--keep` takes category ids. Unknown ids are a usage error. `unslim` converges
to an empty desired set, which re-enables every managed label.

### Flow (`SimulatorSlimService`)

1. Acquire every lane through `LeaseCoordinator.acquire` (exclusive).
   Acquire with `allowUnfinishedRepair: true`, then validate any journal.
2. If `device-recovery.json` exists: it must be a slim transaction for this
   device, `--settled` must be given and its recorded owner must have exited.
   Otherwise fail. Without a pending transaction, `--settled` is ignored.
3. Ingest crash reports first (the same `inspect` closure `status` uses).
   Preconditions: device exists, `available`, unpaired, runtime passes the
   gate. `slim` also requires no crash block; `unslim` is allowed on a blocked
   device and keeps the block. The device must be `Shutdown`, except when
   resuming a settled slim journal, where a `Booted` device is shut down and
   verified first.
4. Write a `DeviceRepairTransaction` with `purpose: "slim"` to
   `device-recovery.json` before any device command. Existing admission gates
   already refuse new work while this file exists. Then write the profile entry
   with `complete: false` (or, for `unslim`, mark the existing entry
   incomplete) so no partial state is ever untracked.
5. Boot and wait. Read `launchctl print-disabled system` through
   `simctl spawn`, retrying failed reads after 1, 2, 4 and 8 s (launchd_sim
   refuses spawns briefly after boot). Compute `toDisable` and `toEnable` against `managed`.
6. Apply each transition with `simctl spawn UUID launchctl disable|enable
   system/LABEL`, up to 8 at a time, up to 3 passes with 1 s then 2 s pauses.
7. If anything changed: shut down, boot and wait, read the disabled set again.
   Any remaining delta fails the command.
8. Shut down and verify `Shutdown`.
9. Mark the profile `complete: true` in `slim-profiles.json` (`keep`,
   desired label count, `appliedAt`), or remove the entry for `unslim`.
   Delete the transaction.

Errors:

- `DeviceManagementError.failed` during steps 5 to 7: attempt shutdown. If
  `Shutdown` is verified, delete the transaction and rethrow; the profile entry
  stays `complete: false`, and status and doctor report it as incomplete until
  `slim` or `unslim` succeeds. If shutdown is not verified, keep the
  transaction and throw `unsettled`.
- `unsettled` (timeouts): keep the transaction. The user reruns the same
  command with `--settled` after confirming no device work remains. Because the
  flow converges to the desired state, a rerun is safe.
- `device repair` refuses a pending transaction whose `purpose` is `slim`.
  `device recover --settled` keeps its existing behavior for any transaction.

Result JSON: `{deviceID, state: "slimmed"|"restored"|"unchanged",
disabledCount, keep}`.

### Visibility and drift

- `SimulatorUsage` gains optional `slim: {keep, disabledCount, complete}` from
  `slim-profiles.json`.
- `doctor` reports, for each recorded profile: device missing from inventory,
  or, for a `Booted` device, drift between the recorded desired set and the
  live `print-disabled` output (labels re-enabled or newly disabled). Shut-down
  devices are not booted by doctor.
- The menu phone card shows `Slim` in its detail line.

### Interactions

- PosterBoard is in the widgets category. Crash reports can arrive late, so a
  PosterBoard block can appear after slimming. Automatic recovery's
  verification skips the PosterBoard PID requirement when the device's slim
  profile disables PosterBoard. SpringBoard stays enabled.
- Crash evidence comes from the host's `~/Library/Logs/DiagnosticReports`; the
  catalog does not touch host services.
- Repairs that replace a slim device produce a stock device with a new UUID.
  Doctor reports the old profile as missing.
- Warm devices are `Booted` and are refused until shut down.

Not ported: offline `disabled.plist` writes, the auto-slim watcher, device
cloning, live (no-reboot) slimming.

## 3. Device caches and logs in Storage Cleanup

- New `CleanupTargetKind.deviceData` and `CleanupCategory.simulatorDeviceData`,
  one target per shut-down device with a valid data path: "Caches, logs and
  temporary files". Rebuildable, delete permanently, selected by default.
- Target directories inside the device data path, never following symlinks and
  rejecting anything that resolves outside it:
  - every directory named `Caches` or `tmp` found by walking the data path,
    skipping `Containers/Bundle`, `Documents`, `Mobile Documents`, `Media` and
    `MobileAsset` subtrees, and not descending into a found target;
  - `Library/Logs`, `var/log`, `var/db/diagnostics`, `var/db/uuidtext`.
- Only the children of each target directory are deleted. The directories
  stay.
- Booted, leased, warm or otherwise protected devices are listed as protected
  with reason `booted` or the existing reasons.
- Device data targets count as simulator targets for lease acquisition in
  `CleanupService.apply`: when the lease is busy they are deferred like
  devices and runtimes.
- The fingerprint is a new `CleanupFingerprint.deviceData(path:digest:)`:
  SHA-256 over the sorted relative path, type, size, inode and modification
  time of every target and descendant, read with `lstat`.
- Apply revalidates the device (still `Shutdown`, same data path), recomputes
  the targets and digest, and skips the target on any change.
- Deletion never resolves symlinks. Each target directory must be a real
  directory with no symlink in any path component below the data path. Each
  child is removed with `FileManager.removeItem`, which unlinks symlinks
  rather than following them. `CleanupFileOperator` is not used because it
  resolves symlinks before deleting.
- Text and menu cleanup views show the new category under simulators.

## Testing

Unit tests cover meaningful logic only:

- `launchd_sim` argument UUID extraction, tree walk, CPU delta math.
- `print-disabled` parsing, runtime gate parsing, profile `desired` and delta
  computation including shared labels and protected labels.
- Slim service state machine with fake device and launchd controllers:
  unchanged, slimmed, verification failure, settled resume, refused
  preconditions.
- Device data target discovery and protected-subtree exclusion on a temp tree,
  and apply revalidation.
- Command parsing for the new commands.

Manual verification on one disposable iOS 18.5+ device via `simlease run`:
`measure` before slim, `slim`, boot, `measure` after, `unslim`.
