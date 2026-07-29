# Stale Simulator Cleanup Design

**Date:** 2026-07-29  
**Product:** SimLease  
**Status:** Approved conversational design; awaiting written-spec review

## 1. Goal

Add an explicitly approved cleanup flow that frees storage used by stale
simulator devices and Apple-reported outdated simulator runtimes.

Cleanup is available from both the `simlease` CLI and the menu-bar application.
Every cleanup is a two-step operation: first create and review an exact plan,
then apply that same plan by entering its confirmation ID.

## 2. Scope

### 2.1 Included

- shutdown simulator devices with an Apple-reported `lastUsedAt` at least
  30 days old
- runtimes reported by
  `xcrun simctl runtime delete --outdated --dry-run`
- exact target names, identifiers, last-use dates, available sizes, and
  estimated known-size total
- protected-target reporting with explicit reasons
- plan persistence, expiry, integrity checking, and one-time application
- immediate revalidation before deletion
- per-target execution results and measured free-space change
- CLI and native menu-bar interfaces

### 2.2 Excluded

- automatic or scheduled cleanup
- cleanup without an explicit plan and confirmation ID
- force-releasing an active SimLease
- deleting booted devices
- deleting a runtime used by any booted device
- deleting runtimes based on age alone
- deleting devices whose last-use date is unknown
- DerivedData, `.xcresult` bundles, simulator logs, application data, or
  project worktrees
- arbitrary target selection or additional storage-cleanup categories

## 3. Architecture

Cleanup logic lives in `SimLeaseCore` so the CLI and menu use the same models,
eligibility rules, persistence, and executor.

### 3.1 CleanupInventory

`CleanupInventory` gathers literal machine state while holding the SimLease:

- `xcrun simctl list devices -j`
- `xcrun simctl runtime list -j`
- `xcrun simctl runtime delete --outdated --dry-run`
- current free-space data for the volume containing CoreSimulator storage
- active `xcodebuild` test processes

The inventory parser consumes Apple-reported `lastUsedAt`, `dataPath`,
`dataPathSize`, state, runtime grouping, runtime identifiers, and runtime size
when available. Unknown values remain unknown.

### 3.2 CleanupPlanner

`CleanupPlanner` is a pure projection from an inventory and clock to a
`CleanupPlan`.

A device is eligible only when:

1. its state is `Shutdown`
2. `lastUsedAt` exists and is at least 30 days before plan creation
3. its UUID and data path agree
4. its standardized data path is inside
   `~/Library/Developer/CoreSimulator/Devices/<UUID>`
5. no active `xcodebuild` test process exists

A runtime is eligible only when:

1. Apple's `--outdated --dry-run` identifies it
2. the runtime has an exact identifier
3. no booted device uses it
4. no active `xcodebuild` test process exists

Every non-eligible device and runtime is retained in the plan's protected list
with a machine-readable reason and user-facing explanation.

### 3.3 CleanupPlanStore

Plans are atomically stored under:

```text
~/Library/Caches/com.jdelaire.simlease/cleanup-plans/
```

The directory uses mode `0700`; plan files use mode `0600`. Each plan contains:

- unique random six-character confirmation ID
- creation and expiry dates
- 10-minute expiry
- exact device and runtime targets
- protected targets and reasons
- estimated bytes
- source inventory summary
- SHA-256 digest of the canonical plan payload

The digest detects accidental plan modification. It is an integrity check, not
a security boundary against the current macOS account.

Apply consumes the plan after one attempt, whether the result is complete,
partial, expired, or rejected. Old unconsumed plan files may be pruned after
24 hours.

If an inventory contains no eligible targets, the planner returns an empty
review without storing a plan or issuing a confirmation ID.

### 3.4 CleanupExecutor

`CleanupExecutor` acquires the SimLease before doing any CoreSimulator work.
It then:

1. loads and verifies the exact plan
2. rejects expired or malformed plans
3. gathers a fresh inventory
4. verifies that no protected activity has appeared
5. revalidates every planned device and runtime
6. deletes still-eligible devices by exact UUID
7. gathers runtime state and dry-run output again
8. deletes still-eligible runtimes by exact identifier
9. measures free space again
10. returns a structured result

Targets that disappeared or became ineligible are skipped. New candidates are
never added. A skipped or failed device does not authorize a substitute.

Device deletion runs before runtime deletion. Any device deletion failure is
reported, and any failure that makes the refreshed runtime inventory
untrustworthy stops the runtime phase. Runtime deletion never uses the broad
`--outdated` apply form; it uses exact identifiers from the approved plan.

Immediately before each deletion, the executor refreshes the target's state.
This avoids replaying stale UUIDs and protects targets that boot or otherwise
change after global revalidation.

## 4. CLI

### 4.1 Create a plan

```sh
simlease clean plan
simlease clean plan --json
```

Human output groups:

- eligible devices
- eligible runtimes
- protected devices and runtimes with reasons
- unknown sizes
- estimated total recovery
- confirmation ID and expiry time

If any required `simctl` response is invalid or incomplete, planning fails and
stores no plan.

### 4.2 Apply a plan

```sh
simlease clean apply ABC123
simlease clean apply ABC123 --json
```

The ID must exactly match an unexpired stored plan. Apply never accepts inline
UUIDs, runtime identifiers, age overrides, or a global `--yes`.

Exit behavior:

- `0`: every planned target remained eligible and was deleted successfully
- `64`: invalid command or confirmation ID format
- `73`: expired, consumed, missing, or integrity-invalid plan
- `74`: inventory or execution setup failure
- `75`: SimLease acquisition timeout
- `76`: partial cleanup; structured output identifies deleted, skipped, and
  failed targets

Any skipped or failed planned target produces exit `76`.

## 5. Menu-Bar Interface

The existing status popover gains one non-destructive entry point:

```text
Review Cleanup…
```

It opens a cleanup review window rather than deleting from the compact status
popover.

The review window contains:

1. plan creation progress
2. Devices section
3. Runtimes section
4. Protected section
5. target counts and estimated recovery
6. exact confirmation ID
7. a text field requiring the ID
8. `Apply Cleanup` and `Cancel`

`Apply Cleanup` remains disabled until the typed ID matches. The review has no
hidden default targets and no per-target selection in version one.

During execution, the window shows each exact target and its current state.
Completion separates:

- Deleted
- Skipped
- Failed
- estimated bytes
- measured free-space change

The menu's existing status refresh remains read-only and separate from cleanup.
No cleanup starts from periodic refresh, app launch, or login.

## 6. Concurrency and Safety

- Planning and application both attempt a non-waiting acquisition of the same
  system-wide SimLease used by protected simulator commands.
- A busy lease returns exit `75`, shows the current owner, and performs no
  cleanup.
- Cleanup child commands run with `SIMLEASE_HELD=1` to avoid recursive lease
  acquisition.
- Apply checks for active `xcodebuild` test actions before global validation
  and again before deletion.
- Booted devices are always protected.
- A runtime with any booted device is always protected.
- Missing age, path, identifier, or dry-run membership never becomes an
  inferred deletion fact. Missing size alone may leave an otherwise eligible
  target with an `Unknown` estimate.
- Runtime deletion is exact because `simctl runtime delete` can otherwise
  shutdown devices and unmount images.

## 7. Errors and Recovery

- Invalid JSON or unparseable runtime dry-run output creates no plan.
- A plan that expires or fails integrity validation must be regenerated.
- Inventory drift never broadens scope; changed targets are skipped.
- A target that returns `Invalid device` is refreshed and reported as skipped,
  not retried from stale state.
- Partial results remain visible and copyable in CLI JSON and the menu result
  view.
- Apply does not roll back successful deletions.
- SimLease cache metadata and cleanup results never claim physical recovery
  equal to logical target sizes. Estimated and measured values remain separate.

## 8. Testing

### 8.1 Unit tests

- device and runtime inventory decoding
- exact 30-day boundary
- unknown-date protection
- booted-device protection
- runtime dry-run membership
- booted-runtime protection
- path/UUID agreement and traversal rejection
- unknown-size handling
- plan expiry and one-time consumption
- canonical digest and tamper rejection
- result aggregation and exit-code mapping

### 8.2 Executor tests

A fake `simctl` executable verifies:

- only approved read and delete commands run
- exact device UUID deletion
- exact runtime identifier deletion
- device-before-runtime ordering
- no broad runtime apply command
- fresh revalidation before every deletion
- drift causes skip
- new candidates are ignored
- active tests block deletion
- partial device failure can stop runtime phase

### 8.3 Menu tests

- plan loading, busy, empty, review, confirmation, progress, partial, and
  complete states
- typed ID enables Apply only on exact match
- no cleanup starts from periodic status refresh
- result groups preserve executor ordering and reasons

### 8.4 End-to-end validation

Automated smoke uses fake CoreSimulator data and fake executables. It never
touches real simulator storage.

Real-machine validation first runs only:

```sh
simlease clean plan
xcrun simctl runtime delete --outdated --dry-run
```

Before any real deletion, show the user the exact refreshed device UUIDs,
runtime identifiers, exclusions, and estimated recovery, then obtain explicit
approval for that exact plan.

## 9. Success Criteria

- Both CLI and menu can create the same cleanup plan.
- No deletion occurs without a matching, unexpired confirmation ID.
- Only shutdown devices unused for at least 30 days are eligible.
- Only Apple-reported outdated runtimes are eligible.
- Booted devices and their runtimes are never deleted.
- Every target is revalidated immediately before deletion.
- New or changed targets are never substituted.
- Results distinguish deleted, skipped, failed, estimated, and measured values.
- Automated tests never mutate real CoreSimulator state.
- Real cleanup requires a separate, exact user approval after live inventory.
