# Task-owned simulator lifecycle

## Outcome

Simulator validation holds the existing host-wide lane for the whole job. Simulators started for that job are shut down before the lane is released. Existing user devices remain running. The implementation is installed on this Mac after validation.

## Interface

`simlease run [--device UUID ...] [--keep-running] -- COMMAND [ARG ...]` accepts PATH commands and absolute executables. Multiple commands use a shell script inside this scope. Exact simulator UUID destinations can be inferred for direct xcodebuild invocations. Unknown destinations remain serialized and require explicit device selection for automatic shutdown. Parallel test simulator cloning is disabled for managed test jobs.

`simlease hold --title TITLE --project PROJECT [--device UUID ...]` reserves a native GUI/MCP verification session until interrupted, with the same device ownership and cleanup. `simlease doctor --json` reports PATH coverage and known unmanaged tool processes.

`simlease recover` reconciles unfinished task journals under the same global lane. `simlease status --json` exposes an unfinished journal as an error when the lane is free. Recovery runs before new protected work. No force-release command is introduced.

## Ownership and cleanup

The lane is acquired before inventory or recovery. A journal records task token, exact kernel process identity, declared device IDs, devices initially shut down, child identity, phase and cleanup failures. It is durable before child execution. Prebooted devices are borrowed and are never automatically powered off. `--keep-running` explicitly retains devices.

The supervised child runs in its own process group and waits on a parent-owned pipe until its identity is journaled. Cleanup waits for the child while retaining its identity, terminates only its verified process group, then shuts down owned devices with a deadline and checks their final state. Success with failed cleanup returns an error; an existing job failure retains its original exit code. A failed journal blocks admission until recovery succeeds.

An owned device removed by the task is settled after a successful full simulator inventory proves it is absent. Unavailable devices remain in that inventory, and inventory errors still block cleanup.

Recovery requires a provably dead or reused task owner. It signals a child group only while a recorded exact process identity verifies ownership. Unknown or ambiguous ownership remains blocked. A heartbeat timeout alone never establishes ownership loss.

## Coordination and coverage

Keep the current single global lane. Fix same-process POSIX-lock probing and descriptor inheritance. Nested commands must validate a random token, live owner identity and ancestry; the old environment flag alone cannot bypass coordination.

Expand command shims for nested xcrun xcodebuild and ordinary agent-device commands. A persistent daemon command must not monopolize the lane. Explicit run scopes cover absolute commands. PATH shims cannot intercept GUI Xcode or arbitrary absolute launches; those callers must use run/hold or integrate the API. Installation adds supported shims and agent workflow guidance, and identifies this coverage limit.

Agent-device internal tool lookup excludes SimLease shims to prevent recursive acquisition by its external daemon. Client exit does not establish daemon request settlement; native integrations must retain a reservation until external work finishes.

## Validation and rollout

Use serial Swift builds and meaningful subprocess, lifecycle and ownership tests. Cover exclusion, status probing, inherited-marker bypass, journal-before-exec, child failure and cancellation, prebooted protection, quarantine, stale-owner recovery, PID reuse and unsupported destinations. Run existing installer tests, install the app and CLI, and perform a real smoke test with an isolated simulator. Never stop existing user jobs to make the smoke test pass.

Implement on a feature branch, preserve existing untracked files, review with Sol 6.1 at extra-high reasoning, merge to main, push and delete the feature branch.
