# Stale Waiter Pruning and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove dead or PID-reused waiter metadata from live status and publish SimLease 0.1.2.

**Architecture:** `LeaseCoordinator` filters persisted waiters through an injected process-identity inspector. The production inspector uses Darwin process start data; tests inject exact outcomes. The existing tag workflow owns signing, notarization, and release publication.

**Tech Stack:** Swift 6, Foundation, Darwin `proc_pidinfo`, XCTest, zsh, GitHub Actions, GitHub CLI.

## Global Constraints

- Do not terminate processes while pruning waiter metadata.
- Fail open when process identity cannot be established.
- Preserve existing waiter JSON compatibility.
- Keep CLI and bundle versions identical at `0.1.2`.
- Publish signed assets only through `.github/workflows/release.yml`.

---

### Task 1: Process Identity Inspection

**Files:**
- Create: `Sources/SimLeaseCore/ProcessIdentityInspector.swift`
- Create: `Tests/SimLeaseCoreTests/ProcessIdentityInspectorTests.swift`

**Interfaces:**
- Produces: `ProcessIdentityState` with `matching`, `missing`, `reused`, and `unknown`.
- Produces: `ProcessIdentityInspecting.identityState(pid:waitingSince:)`.
- Produces: `SystemProcessIdentityInspector`.

- [ ] **Step 1: Write failing inspector tests**

Test the current PID with a current wait timestamp, the current PID with a
timestamp before its real start, and `Int32.max` as a missing PID.

- [ ] **Step 2: Verify the tests fail**

Run:

```sh
swift test --filter ProcessIdentityInspectorTests
```

Expected: compile failure because the inspector API does not exist.

- [ ] **Step 3: Implement the production inspector**

Use `kill(pid, 0)` to distinguish a missing process, then
`proc_pidinfo(PROC_PIDTBSDINFO)` to obtain its start timestamp. Return
`reused` only when start time is more than one second newer than
`waitingSince`; return `unknown` on any inconclusive lookup.

- [ ] **Step 4: Verify inspector tests pass**

Run:

```sh
swift test --filter ProcessIdentityInspectorTests
```

Expected: all selected tests pass.

### Task 2: Status-Time Pruning

**Files:**
- Modify: `Sources/SimLeaseCore/LeaseCoordinator.swift`
- Modify: `Tests/SimLeaseCoreTests/LeaseCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ProcessIdentityInspecting.identityState(pid:waitingSince:)`.
- Produces: status containing only matching or unknown waiters.

- [ ] **Step 1: Write a failing coordinator regression test**

Persist matching, missing, reused, and unknown waiters. Assert that status and
the metadata store retain only matching and unknown waiters.

- [ ] **Step 2: Verify the regression test fails**

Run:

```sh
swift test --filter LeaseCoordinatorTests/testStatusPrunesStaleWaiters
```

Expected: missing and reused waiters remain visible.

- [ ] **Step 3: Implement minimal pruning**

Inject the inspector into `LeaseCoordinator`. During `status()`, remove missing
and reused waiter files and exclude them from the returned array. Keep matching
and unknown entries.

- [ ] **Step 4: Verify coordinator and core tests**

Run:

```sh
swift test --filter LeaseCoordinatorTests
swift test
```

Expected: all tests pass.

### Task 3: Version and Release Validation

**Files:**
- Modify: `Sources/SimLeaseCLI/SimLeaseBuild.swift`
- Modify: `Resources/SimLease-Info.plist`
- Modify: `Tests/SimLeaseCLITests/CLIScaffoldTests.swift`
- Modify: `Tests/InstallationTests/package-release.zsh`
- Modify: `Tests/InstallationTests/install-release.zsh`

**Interfaces:**
- Produces: CLI and app version `0.1.2`.

- [ ] **Step 1: Update version expectations first**

Change test fixtures and assertions from `0.1.1` to `0.1.2`.

- [ ] **Step 2: Verify version tests fail**

Run:

```sh
swift test --filter CLIScaffoldTests/testVersionPrintsPublicVersion
zsh Tests/InstallationTests/package-release.zsh
```

Expected: CLI or bundle version mismatch.

- [ ] **Step 3: Update production versions**

Set `SimLeaseBuild.currentVersion` and `CFBundleShortVersionString` to `0.1.2`.

- [ ] **Step 4: Run release gates**

Run:

```sh
swift test
zsh Tests/SmokeTests/cleanup-smoke.zsh
zsh Tests/InstallationTests/install-cli.zsh
zsh Tests/InstallationTests/package-app.zsh
zsh Tests/InstallationTests/install-app.zsh
zsh Tests/InstallationTests/install-relaunch.zsh
zsh Tests/InstallationTests/package-release.zsh
zsh Tests/InstallationTests/install-release.zsh
```

Expected: every command exits zero.

### Task 4: Install and Publish 0.1.2

**Files:**
- No additional source files.

**Interfaces:**
- Produces: merged `main`, tag `v0.1.2`, signed and notarized GitHub release.

- [ ] **Step 1: Install and verify local runtime**

Package and install the app. Confirm launchd maps the running executable to
`~/Applications/SimLease.app`, status is free, and the stale waiters disappear.

- [ ] **Step 2: Commit and push the release branch**

Stage only the planned files, commit, and push
`codex/stale-waiter-pruning-0.1.2`.

- [ ] **Step 3: Open and merge the PR**

Create a ready PR against `main`, wait for required checks, and merge only when
GitHub reports it mergeable with no failing or pending checks.

- [ ] **Step 4: Tag the merge commit**

Create annotated tag `v0.1.2` at the verified `main` merge commit and push it.

- [ ] **Step 5: Verify the release workflow**

Wait for the tag-triggered Release workflow. Verify the published release is
latest, both assets exist, the tag matches the merge commit, and
`simlease update` installs and runs version `0.1.2`.
