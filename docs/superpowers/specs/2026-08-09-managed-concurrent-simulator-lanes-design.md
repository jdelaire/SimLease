# Managed Concurrent Simulator Lanes Design

## Summary

SimLease will add managed simulator lanes for agents that need concurrent iOS
Simulator access. An agent acquires a lane, receives one SimLease-managed
simulator and isolated build paths, uses that lane across multiple commands,
then releases it explicitly.

The feature permits bounded concurrency without treating separate simulator
UDIDs as fully independent machines. Commands that mutate global
CoreSimulator state remain serialized. Commands scoped to different managed
devices may run concurrently up to a configurable limit of two lanes by
default.

## Goals

- Give agents one explicit command for safely acquiring a simulator.
- Return copyable human guidance and stable machine-readable instructions.
- Isolate simulator identity, build data, and command execution per lane.
- Permit bounded parallel work on distinct managed simulators.
- Serialize operations that can affect global CoreSimulator state.
- Preserve existing single-lane SimLease behavior for callers that do not opt
  into managed lanes.
- Never force-release an owner, terminate a foreign process, or mutate a
  simulator that SimLease did not create and identify exactly.
- Make normal release non-destructive and simulator deletion explicit,
  reviewed, and revalidated.

## Non-goals

- Downloading or installing simulator runtimes.
- Making CoreSimulatorService itself process-isolated.
- Automatically choosing unbounded concurrency from machine resources.
- Silently rewriting arbitrary `xcodebuild`, `xcrun`, or AXe commands.
- Managing physical devices.
- Deleting foreign simulators or reclaiming stale lanes automatically.
- Replacing focused simulator proof with physical-device proof.

## User-facing workflow

### Acquire a lane

An agent requests a lane with an explicit project, device type, and runtime:

```sh
simlease lane acquire \
  --project ExplorerDex \
  --device-type "iPhone 17 Pro" \
  --runtime latest \
  --json
```

`latest` means the newest compatible runtime already installed on the Mac. It
never authorizes a download. Exact runtime identifiers remain accepted for
reproducible work.

Under one global control lock, SimLease will:

1. inspect current reservations and capacity;
2. resolve the requested runtime and device type from local CoreSimulator
   inventory;
3. reuse a compatible idle SimLease-managed simulator when possible;
4. otherwise acquire every lane command lock in a fixed order and create one
   new SimLease-managed simulator;
5. write a private lane descriptor and ownership record atomically; and
6. return the lane instructions.

If two lanes are already reserved, acquire exits with code `75`. Human output
identifies the current owners and safe next action. JSON reports a
`capacityFull` state and current wait information. The command does not create
another simulator or evict an owner.

If a runtime or device type is unavailable or ambiguous, acquire performs no
mutation. It returns the locally valid choices and a corrected command shape.

### Use the lane

Acquire writes a `0600` lane descriptor under SimLease-owned cache storage and
returns its path:

```sh
export SIMLEASE_LANE_FILE="/path/returned/by/simlease"
```

The descriptor contains the lane ID, an unguessable ownership token, project,
thread identity when available, managed simulator UDID, resolved runtime and
device type, DerivedData path, creation metadata, and last activity time. The
ownership token is not placed in command-line arguments.

Human output includes exact examples for the acquired lane. JSON contains at
least these stable fields:

```json
{
  "schemaVersion": 1,
  "state": "acquired",
  "lane": {
    "id": "lane-1",
    "udid": "SIMULATOR-UDID",
    "deviceType": "iPhone 17 Pro",
    "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    "expiresAt": "2026-08-09T10:00:00Z"
  },
  "environment": {
    "SIMLEASE_LANE_FILE": "/private/path/to/lane.json"
  },
  "xcodebuildArguments": [
    "-destination",
    "platform=iOS Simulator,id=SIMULATOR-UDID",
    "-derivedDataPath",
    "/private/path/to/DerivedData"
  ],
  "derivedDataPath": "/private/path/to/DerivedData",
  "releaseCommand": ["simlease", "lane", "release"],
  "nextActions": []
}
```

The first contract uses `schemaVersion: 1`. Fields will be additive within a
schema version so agents can safely decode the minimum contract. Removing,
renaming, or changing the meaning of a field requires a new schema version.

When `SIMLEASE_LANE_FILE` is present, command shims validate the descriptor,
ownership token, reservation, and requested target before execution:

- `xcodebuild` simulator work must target the lane UDID and use the lane's
  DerivedData path.
- device-scoped `xcrun simctl` work must target the lane UDID.
- AXe work must select the lane UDID using the installed AXe version's
  documented device selector. If that AXe version provides no unambiguous UDID
  selector, lane-scoped AXe work is refused with an unsupported-version error.
- commands that address another UDID or shared DerivedData fail before the
  child process starts.

Validation failures print the exact corrected arguments. Shims do not silently
inject or replace destinations because hidden rewriting would make logs and
result evidence misleading.

### Inspect lanes

```sh
simlease lane status
simlease lane status --json
```

Status reports configured capacity, reserved and available slots, owner and
thread identity, simulator UDID, runtime, device type, current command
activity, last activity, and any recovery-required state. Tokens and other
secrets are never printed.

### Release a lane

```sh
simlease lane release
```

Release reads `SIMLEASE_LANE_FILE`, validates the ownership token, waits for
the lane's active command lock, and shuts down only the exact matching
SimLease-managed simulator. It then removes the reservation and makes the
slot available. The simulator remains in an idle managed pool for later reuse.

Release prints an optional disposal plan. Deletion is deliberately separate:

```sh
simlease lane dispose plan SIMULATOR-UDID
simlease lane dispose apply PLAN-ID --target SIMULATOR-UDID
```

Apply succeeds only if the plan is current and single-use, the device remains
unreserved and shut down, its UUID and data path match the SimLease creation
record, no active lane command targets it, and current inventory still matches
the reviewed fingerprint. Any mismatch aborts deletion. Foreign simulators
are never eligible.

## Concurrency model

### Reservation and ownership

Lane reservation is persistent across commands. SimLease creates reservations
atomically under a global control lock and protects each with a random token
stored only in the private lane descriptor and private metadata.

Because the acquiring CLI exits while the agent continues to work, an
acquisition-time process lock cannot represent lane ownership. The reservation
record is therefore the durable allocation contract. Per-command locks remain
OS-enforced and authoritative for active use.

Reservations are not force-reclaimed. Shim invocations update last activity
and extend a two-hour idle expiry. An abandoned or inconsistent reservation
becomes `recoveryRequired`; it does not silently become another agent's lane.
Recovery is two-step:

```sh
simlease lane recover plan LANE-ID
simlease lane recover apply PLAN-ID --lane LANE-ID
```

Planning requires an expired reservation or internally inconsistent metadata.
Apply reacquires the control lock, proves the lane command lock is free,
revalidates the owner and managed device fingerprint, and refuses if activity
resumed after planning. Successful recovery shuts down the exact managed
device when needed and releases the reservation without deleting the device.
It never terminates a process. Plans expire after ten minutes and can be used
once.

### Per-lane command locks

Every slot has one command lock. A shim using a managed lane holds that lock
for the complete child-process lifetime. This serializes commands within one
lane while allowing commands in different lanes to overlap.

The default capacity is two lanes. Capacity is stored in SimLease configuration
and can be changed explicitly. Reducing capacity never evicts an existing lane;
the lower cap takes effect as reservations are released.

```sh
simlease lane config
simlease lane config --max-active 2
```

The configured maximum must be a positive integer. Configuration output also
reports the effective maximum and current reservation count.

### Global operations

Operations that can affect shared CoreSimulator state acquire the global
control lock and every lane command lock in deterministic slot order. These
include:

- simulator creation and deletion;
- runtime mutation;
- stale-lane recovery that changes simulator state;
- legacy simulator commands without a lane descriptor;
- `simlease hold` for manual Xcode use; and
- any command whose target cannot be proven to be exactly one managed lane.

Fixed lock ordering is mandatory: control lock first, then lane command locks
in ascending slot order. No code path may acquire those locks in reverse.

Read-only inventory may later receive a narrower concurrency classification,
but the first implementation treats unscoped inventory as global for safety.

## Compatibility

Existing commands remain valid:

- `simlease status` and `simlease status --json` keep their existing contract;
- current shims without `SIMLEASE_LANE_FILE` use legacy exclusive mode;
- `simlease hold` remains the safe path for Xcode GUI work; and
- SimLease still has no force-release command.

Legacy exclusive commands wait until all lane command locks are available.
This preserves safety for installed agents and scripts while managed lane
support is adopted gradually. A legacy command that explicitly targets a
currently reserved managed UDID is refused; the owner must use its lane
descriptor. Legacy commands may still use foreign simulators under the global
exclusive lock.

The installer continues putting SimLease shims first on PATH. Agents must still
verify that `xcodebuild`, `xcrun`, and `axe` resolve through those shims and must
not bypass them with absolute paths.

## Managed device identity

Every device created by this feature receives:

- a deterministic SimLease name containing a short lane or pool identifier;
- a creation record with UUID, runtime identifier, device type identifier,
  expected CoreSimulator data path, creation date, and record format version;
- a lifecycle state of reserved, idle, recovery-required, or disposal-planned;
  and
- a fingerprint used for release, recovery, and disposal validation.

The creation record is necessary but not sufficient for mutation. SimLease
must also query current CoreSimulator inventory and verify exact identity and
state immediately before shutdown or deletion.

## DerivedData isolation

Each lane receives a stable SimLease-owned DerivedData directory scoped by lane
and project identity. Repeated commands in one lane can reuse build output.
Separate lanes never share that path.

Release does not automatically delete DerivedData. Existing explicit storage
cleanup policy remains responsible for aged cache removal. Cleanup must treat
active or reserved lane paths as protected.

Result bundle paths remain the caller's responsibility, but human and JSON
guidance will recommend a lane-unique result bundle path for every test run.

## Error behavior

Errors must distinguish product failures from infrastructure and policy
failures. At minimum:

- `capacityFull`: no lane available; owner/wait guidance returned;
- `runtimeUnavailable`: requested runtime not locally installed or available;
- `deviceTypeUnavailable`: requested device type not available;
- `invalidLaneDescriptor`: missing, unreadable, or schema-incompatible file;
- `laneOwnershipMismatch`: descriptor token does not own reservation;
- `targetMismatch`: command points at another simulator;
- `derivedDataMismatch`: command would share or bypass isolated build data;
- `globalMutationBusy`: safe global operation cannot yet acquire all lanes;
- `laneRecoveryTooRecent`: reservation has not reached its two-hour idle
  expiry;
- `unsupportedAXeTargeting`: installed AXe cannot select one exact UDID;
- `recoveryRequired`: metadata or simulator state is inconsistent; and
- `metadataError`: authoritative decision cannot be made safely.

No error path claims a test result. A child process that never starts, a run
with zero tests, a timeout, or an unfinalized result bundle remains
infrastructure evidence only.

## Testing strategy

Implementation will be test-driven. Most coverage must use injected process,
inventory, filesystem, and clock dependencies so it does not require a live
simulator.

Required automated coverage:

- parser acceptance and rejection for every lane subcommand;
- stable human and JSON output contracts;
- local runtime and device-type resolution, including ambiguity and `latest`;
- atomic allocation at capacity under simultaneous acquire attempts;
- configuration validation and capacity reduction without eviction;
- same-lane serialization and distinct-lane concurrency;
- deterministic global lock ordering and exclusion;
- unique DerivedData allocation per project and lane;
- shim validation for correct and incorrect destinations and build paths;
- legacy no-lane exclusive behavior;
- exact managed-device identity and foreign-device rejection;
- normal release, interrupted release, and idempotent retry behavior;
- expired, missing, corrupt, and ownership-mismatched descriptors;
- idle-expiry renewal, recovery planning, one-time apply, resumed-activity
  rejection, and no automatic reclamation;
- disposal plan expiry, one-time use, fingerprint changes, new reservations,
  booted devices, and foreign devices;
- cleanup protection for active lane artifacts; and
- installed/package CLI usage containing lane commands.

Integration coverage will run multiple CLI processes against a temporary
SimLease root and fake `xcrun` executable to prove real lock behavior.

A final live smoke test will separately verify creation, two distinct managed
UDIDs, concurrent lane-scoped commands, release, reuse, and explicit disposal.
Before that smoke test, the operator must run `simlease status --json`, verify
all simulator tools resolve through SimLease shims, and obey the current lease
state. A blocked or incomplete smoke test will be reported separately from the
automated suite.

## Documentation and agent guidance

README agent workflow will gain the lane acquire/use/release flow, JSON example,
capacity behavior, legacy compatibility, and disposal warning. Usage text will
include the new `lane` command family.

The human output itself is part of the agent interface. Every blocked state
must state:

1. what SimLease observed;
2. why it refused to proceed;
3. whether any state changed;
4. the exact safe next command; and
5. which proof remains unavailable.

## Implementation boundaries

The first implementation will not publish, tag, release, install, or update
the user's active SimLease installation. Those are separate explicit gates
after source tests, integration tests, packaging tests, and live simulator
validation pass.
