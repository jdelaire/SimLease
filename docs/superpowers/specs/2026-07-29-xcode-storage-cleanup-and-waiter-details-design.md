# Xcode Storage Cleanup and Waiter Details Design

**Date:** 2026-07-29  
**Status:** Approved design, pending written-spec review

## Goal

Expand SimLease from stale simulator cleanup into a safety-first Xcode storage
review tool, while making queued simulator users identifiable in the menu-bar
popover.

The feature must help a developer reclaim stale Xcode storage without disrupting
active builds, tests, simulators, source work, or release evidence. Agents must
continue using `simlease status --json` as the authoritative advisory check
before simulator testing.

## Scope

This design adds:

- tiered cleanup review for simulators, rebuildable Xcode caches, and guarded
  artifacts;
- byte-size and age estimates for every candidate;
- explicit item selection and plan-based apply;
- active-use, lease, path, and fingerprint protections;
- detailed cleanup results;
- structured waiter rows showing task context instead of only shortened thread
  IDs;
- richer waiter data in copied details.

This design does not:

- force-release a simulator lease;
- stop Xcode, builds, tests, or simulator processes;
- empty Trash;
- delete source directories, Git worktrees, or files outside validated cleanup
  roots;
- infer that a simulator test may start from cleanup state. Agents still use
  `simlease status --json`.

## Chosen Approach

Use a tiered cleanup review.

A flat list would hide meaningful risk differences. A report-only audit would
not reclaim storage. Tiered review keeps common rebuildable cleanup convenient
while requiring deliberate action for release and diagnostic artifacts.

## Cleanup Categories and Policies

### Simulator storage

Eligible and preselected:

- registered, shutdown simulator devices unused for at least 30 days;
- runtimes reported as outdated by Apple tooling.

Protected:

- booted devices;
- the current lease owner's simulator context;
- any simulator target while SimLease is leased;
- targets whose state changes after the review scan.

Simulator deletion remains permanent and uses the existing narrow `simctl`
operations. SimLease never uses broad commands such as `simctl delete all`.

### Rebuildable caches

Eligible candidates are preselected and permanently deleted after confirmation:

| Category | Stale threshold | Age source |
| --- | ---: | --- |
| Temporary/custom DerivedData | 24 hours | Newest relevant content modification |
| Xcode previews | 7 days | Preview entry modification |
| Standard DerivedData | 14 days | `LastAccessedDate` when present, otherwise newest relevant modification |
| Project `.build` cache | 14 days | Newest relevant content modification |

Temporary/custom DerivedData must pass structural checks proving that the
directory is an Xcode build cache, such as recognized `Build`,
`Intermediates.noindex`, `Products`, or `SourcePackages` contents. A name match
alone is insufficient.

Standard DerivedData is scanned only beneath
`~/Library/Developer/Xcode/DerivedData`. Preview data is scanned only beneath
`~/Library/Developer/Xcode/UserData/Previews`.

Project `.build` directories are discovered only within bounded workspace roots:

- workspace paths referenced by Xcode DerivedData metadata;
- current or recent SimLease owner/waiter working directories.

No unbounded home-directory search is performed.

### Guarded storage

Guarded candidates are visible but never preselected:

| Category | Eligibility |
| --- | --- |
| `.xcresult` bundles | At least 30 days old |
| Xcode Archives | At least 90 days old |
| iOS Device Support | Every discovered device/build folder |

Selected guarded items move to Trash through the system file API. The UI states
that space is reclaimed only after the user empties Trash. SimLease does not
empty Trash.

Result bundles are discovered only inside bounded workspace roots. Archives are
scanned only beneath `~/Library/Developer/Xcode/Archives`. Device Support is
scanned only beneath `~/Library/Developer/Xcode/iOS DeviceSupport`.

Device Support has no automatic stale classification because device/build
usefulness cannot be inferred safely. Each row shows device identifier, OS/build
version, size, and modification date so the user can decide.

## Inventory Architecture

Introduce focused inventory providers behind protocols:

- `SimulatorCleanupScanner`
- `DerivedDataCleanupScanner`
- `PreviewCleanupScanner`
- `SwiftBuildCleanupScanner`
- `ResultBundleCleanupScanner`
- `ArchiveCleanupScanner`
- `DeviceSupportCleanupScanner`
- `ActiveUseProviding`
- `CleanupFileOperating`

Each scanner returns common cleanup candidates without deleting anything.
Scanners own category-specific discovery and age logic; the planner owns
selection defaults and protection rules.

A cleanup candidate contains:

- stable target ID;
- display name and detail;
- canonical path or simulator identifier;
- category and risk tier;
- allocated byte estimate;
- relevant date and computed age;
- eligibility reason;
- protection reasons;
- fingerprint.

Filesystem fingerprints contain canonical path, allocated byte count,
modification date, and category-specific identity. Simulator fingerprints
contain device/runtime identifier plus relevant state and availability fields.

Allocated size is preferred over logical size because the UI describes estimated
disk space. The review includes scan time and per-section totals.

## Workspace Discovery

Workspace roots come from existing local evidence rather than a hard-coded
personal projects directory:

1. Read workspace paths from Xcode DerivedData metadata.
2. Add current and recent SimLease owner/waiter working directories.
3. Canonicalize and deduplicate roots.
4. Reject roots outside the current user's home directory.
5. Never treat a workspace root itself as a cleanup target.

Only recognized `.build` directories and `.xcresult` bundles below these roots
are considered. Symlinks are resolved before allowlist checks, and a resolved
target escaping its allowed root is rejected.

## Planning and Apply Flow

### Review

1. Read SimLease status.
2. Scan bounded filesystem categories.
3. If the lease is free, scan simulator categories.
4. If the lease is leased, show simulator cleanup as deferred while continuing
   filesystem inventory.
5. Detect active Xcode/build/test paths.
6. Classify, protect, size, and group candidates.
7. Save an immutable cleanup plan.
8. Return the plan ID, candidates, totals, protections, and deferred sections.

### Apply

The client submits:

- cleanup plan ID;
- exact selected target IDs.

The executor:

1. Loads the saved plan and rejects an unknown or expired plan.
2. Reads current SimLease status again.
3. Rechecks canonical paths and the category allowlist.
4. Rechecks active-use protection.
5. Re-inventories each selected target.
6. Compares its current fingerprint with the reviewed fingerprint.
7. Skips missing, changed, newly active, booted, or newly protected targets.
8. Permanently deletes eligible simulator/rebuildable targets.
9. Moves selected guarded targets to Trash.
10. Returns one outcome per requested target.

The executor never substitutes a newly discovered target for a selected target.

## Active-Use Protection

`ActiveUseProviding` inspects running Xcode, `xcodebuild`, Swift build, and test
process command lines. Canonical paths referenced by those processes protect the
matching cache target and its containing build root.

If active-use detection fails, apply fails closed for filesystem deletion. A
review may still display candidates, but it marks active-use protection as
unavailable and disables cleanup.

Lease metadata errors block simulator inventory and simulator apply. They do not
permit a fallback simulator command.

## Menu-Bar Cleanup UI

The cleanup window contains:

- title, last scan time, and estimated reclaimable space;
- Simulator Storage section;
- Rebuildable Caches section;
- collapsed Guarded Storage section;
- selected and section-level totals;
- refresh action;
- final confirmation;
- itemized result state.

Every row shows:

- item name;
- category-specific detail such as path, simulator model/runtime, or
  device/build version;
- allocated size;
- age or modification date;
- eligibility or protection reason;
- selection state.

Protected and deferred rows are visible but disabled. Rebuildable eligible rows
start selected. Guarded rows start unselected and use warning styling.

The primary action names the actual operation and amount, for example:

- `Delete 18.4 GB`
- `Move 3 Items to Trash`

When both tiers are selected, confirmation lists permanent deletion and Trash
movement separately. Results group items under Deleted, Moved to Trash,
Protected, Skipped, and Failed.

## Waiter Detail UI

Replace `waiterNames: [String]` with structured display items containing:

- stable waiter ID;
- task title or existing fallback name;
- project;
- source;
- elapsed waiting duration;
- command;
- thread ID;
- working directory.

Each popover row uses the approved compact layout:

1. task title as the primary line;
2. `Project · Source · Waiting duration` as the secondary line.

The full command, thread ID, and working directory remain available through row
help, accessibility content, and Copy Details. Wait durations refresh with the
existing status refresh cycle. Stable waiter IDs, not array offsets, identify
rows.

## CLI and JSON Contract

`simlease status --json` keeps its existing lease-state contract and remains the
agent entry point for deciding whether simulator testing may start.

Cleanup planning returns structured JSON containing:

- plan ID and creation time;
- selected-by-default flag per target;
- category, risk tier, size, age, and reason;
- protection reasons;
- deferred sections;
- total and selected byte estimates.

Cleanup apply requires a plan ID plus target IDs. A plan ID alone no longer
authorizes every target in that plan once selectable categories exist.

Human-readable CLI output mirrors the same sections. JSON decoding in the
menu-bar app must fail with a literal error rather than silently applying a
partial plan.

## Error Handling

- Scanner failure is reported per category when isolation is safe.
- Failure of path canonicalization, active-use detection, plan loading, or plan
  decoding disables apply.
- Individual apply failure does not hide successful or skipped items.
- If a destructive operation begins, remaining unrelated items may continue;
  every outcome is reported.
- No rollback is promised for permanent cache or simulator deletion.
- Trash failures remain failed items and are not converted to permanent
  deletion.
- Refresh discards previous selection and creates a new plan.

## Testing

### Core unit tests

- every age threshold, including exact-boundary behavior;
- size calculation and formatting;
- workspace-root discovery and deduplication;
- structural recognition of temporary DerivedData;
- path canonicalization, symlink escape rejection, and allowlist enforcement;
- risk-tier selection defaults;
- active-process protection;
- lease protection and simulator deferral;
- fingerprint change detection;
- expired, unknown, and mismatched plan rejection;
- permanent-delete versus Trash routing;
- partial outcome reporting.

### CLI and provider tests

- JSON schema for review and apply;
- explicit target selection requirement;
- backward-compatible `status --json`;
- human-readable grouped output;
- literal menu-provider errors for invalid JSON;
- rejection of unsafe broad simulator command shapes.

### Menu-bar tests

- cleanup section grouping, totals, selection, disabled rows, confirmation, and
  results;
- Guarded Storage collapsed and unchecked by default;
- waiter primary and secondary text;
- waiter elapsed-duration refresh;
- duplicate task titles remain distinct through stable waiter IDs;
- accessibility and Copy Details include full waiter context;
- bounded popover/window sizing with long and numerous rows.

### Smoke and live validation

Smoke tests use temporary fixture trees and fake command runners. They prove the
exact paths and simulator IDs routed to delete or Trash without touching real
developer data.

Live simulator validation begins only after:

1. `simlease status --json` reports `free`;
2. `xcodebuild`, `xcrun`, and `axe` resolve through SimLease shims.

Live validation uses disposable simulator/cache fixtures. It never uses active
project DerivedData, current archives, evidence bundles, or the user's booted
simulator.

## Acceptance Criteria

- An agent can still determine simulator availability from
  `simlease status --json`.
- A leased simulator lane prevents simulator inventory and deletion without
  blocking safe filesystem inventory.
- Cleanup review exposes simulator and Xcode storage with sizes, ages, reasons,
  and protections.
- Rebuildable candidates follow the approved thresholds and begin selected.
- `.xcresult`, Archives, and Device Support never begin selected.
- Guarded items move to Trash; SimLease never empties Trash.
- Apply acts only on explicitly selected IDs from an unchanged saved plan.
- Active, changed, booted, out-of-root, or otherwise protected items are never
  deleted.
- Waiter rows show task title plus project, source, and waiting duration.
- Full waiter command, thread ID, and working directory remain accessible and
  copyable.
