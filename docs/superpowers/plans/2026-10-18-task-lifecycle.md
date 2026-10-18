# Simulator task lifecycle implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Serialize simulator tasks and reliably clean up devices they start, then install the verified result.

**Architecture:** Extend the existing single host-wide lane with durable task journals and an explicit run scope. Preserve manual devices and fail closed when cleanup ownership cannot be proved.

**Tech Stack:** Swift 6, Foundation, Darwin POSIX process APIs, existing zsh installer.

**Spec:** `docs/superpowers/specs/2026-10-18-task-lifecycle-design.md`

## Global constraints

- macOS 15+, no new external dependencies.
- No code comments or parallel builds.
- One global lane; preserve prebooted user simulators.
- Exact process identities before destructive recovery; cleanup failure blocks reuse.
- Explicitly document coverage of absolute executables and GUI callers.

## Review focus

- A same-process status query must not unlock an active lease.
- An inherited environment marker must not bypass an unrelated owner.
- A killed parent must not leave an unjournaled executing child.
- A failed shutdown must prevent a later job from starting.
- Device cleanup must not stop a prebooted or unrelated simulator.

### Task 1: Correct host locking and command coverage

**Files:** `LeaseCoordinator.swift`, `LeaseModels.swift`, `ProtectedCommand.swift`, related core tests.

**Interfaces:** Existing coordinator signatures stay compatible. Add exact process references and validated nested ownership for later tasks.

- [x] Add regression tests for same-process status/second acquisition, inherited markers and nested xcrun xcodebuild.
- [x] Run focused tests with `swift test -j 1 --filter LeaseCoordinatorTests` and classifier tests; observe failures.
- [x] Implement process-local coordination around POSIX locks and close-on-exec descriptors.
- [x] Run focused tests, then full serial suite.

### Task 2: Implement task execution and recovery

**Files:** New task models/store, simulator device controller, supervised task runner and lifecycle service; new core lifecycle/process tests.

**Interfaces:** `SimulatorTaskService.run(command:deviceIDs:keepRunning:environment:identity:)` returns the child exit code; `recover` operates under the lane. Inject the simulator boundary for tests while exercising real journals and subprocesses.

- [x] Add failing tests for owned versus borrowed devices, failure cleanup, blocked recovery and journal-before-exec.
- [x] Run focused tests and confirm missing behavior.
- [x] Implement durable journals, exact identities, bounded owned process cleanup and simulator shutdown verification.
- [x] Add cancellation and stale-owner subprocess tests; run focused and full serial suites.

### Task 3: Wire CLI and installation

**Files:** CLI parser/runner, installer scripts, README, installation and CLI tests.

**Interfaces:** Add `run` and `recover`; preserve existing shim and cleanup commands. Expand supported shim dispatch, validate nested task tokens and disable test cloning in managed xcodebuild tasks.

- [x] Add failing parser and CLI tests, including absolute commands and error exit behavior.
- [x] Wire lifecycle service and explicit destination inference.
- [x] Extend installed shims, agent instructions and serial packaging; verify installer behavior.
- [x] Run full serial tests and applicable installation smoke tests.

### Task 4: Review, install and verify

- [x] Request fresh whole-change Sol 6.1 extra-high review and resolve material findings with regression tests.
- [x] Package serially and install through the existing installer.
- [x] Verify command resolution, global exclusion and shutdown with an isolated simulator.
- [x] Merge to main, commit/push and remove the feature branch.

## Execution rulings

The user explicitly requested enhancement and installation after the design discussion. Execute inline without additional approval handoffs. Use an in-place feature branch to reuse the existing build cache and avoid another heavy checkout; preserve the user's untracked `.vscode/` directory. Automatic periodic recovery is deferred; the single recovery path runs before protected jobs and is available explicitly.
