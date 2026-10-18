# Native session implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, with whole-change review before completion.

**Goal:** Give existing Nightly/MCP workflows explicit, crash-safe session controls and expose unmanaged simulator work.

**Architecture:** Extend durable task journals with external session settlement. Reuse the current lane, supervisor and owned-device cleanup. Share a read-only kernel process audit between CLI and menu.

**Tech Stack:** Swift 6, Darwin, Foundation, SwiftUI, existing zsh installer.

**Spec:** `docs/superpowers/specs/2026-10-19-native-sessions-design.md`

## Constraints

- No Nightly source, signed bundle or live userdata changes.
- No automatic takeover based on heartbeat or elapsed time.
- No code comments or parallel builds; preserve `.vscode/`.
- Borrowed devices stay running. All native UUIDs declared before boot.
- Audit is advisory, bounded, and excludes environment/raw arguments from output.

## Review focus

- A durable acknowledgment must survive a keeper crash before settlement journaling.
- Stale acknowledgment and concurrent finish calls cannot settle another task.
- Finish must report actual cleanup failure, not acknowledgment delivery success.
- PID reuse and incomplete inspection cannot produce false verified ownership.
- Idle services and explicit non-simulator targets must not produce unmanaged alerts.

### Task 1: Activity inspection and menu warnings

- [x] Add failing process snapshot and parser tests.
- [x] Implement bounded process capture and shared audit with exact identity checks.
- [x] Add failing menu behavior tests, expose optional activity status and background polling.
- [x] Reuse audit in doctor; test partial capture and target exclusions.

### Task 2: Explicit native session controls

- [x] Add failing lifecycle and CLI tests for unresolved native work, durable/stale acknowledgment, failed finish and competing jobs.
- [x] Add session journal fields and namespaced settlement store; guard cleanup before device shutdown.
- [x] Add begin/finish/private waiter commands, ready JSON and native owner labeling.
- [x] Run serial tests and update native workflow guidance and global agent rules.

### Task 3: Review and installation

- [x] Resolve whole-change review findings; verify meaningful tests.
- [x] Package and install serially; verify passive warnings and T3/MCP native session on a new simulator.
Finalize with one commit, fast-forward main, push, and delete the feature branch.

## Rulings

The user explicitly chose installed Nightly with explicit managed sessions. Execute this scope without another approval handoff. Reuse an in-place feature branch and existing Swift build cache while preserving unrelated files. External daemon settlement is a caller attestation, never inferred from client exit or panel bookkeeping.

The live Nightly device hub has a shimmed PATH. A reviewed extension adds explicit dedicated-helper PID binding, positional simctl target validation and admission locking, avoiding recursive lane acquisition without changing T3. Tests cover target aliases, out-of-scope UUIDs and finish waiting for admitted work.

## Verification

- Serial Swift suite: 178 tests passed, covering native cancellation, keeper death, acknowledgment crashes, stale tokens, failed shutdown, helper target validation, admission drain, audit identity changes and large CLI output.
- Local release package and installation passed. Installer fixture passed. Installed menu launched from its LaunchAgent, and a background status child was observed while no popover was open.
- Live installed Nightly MCP list/open/screenshot/shutdown/reopen/shutdown passed with dedicated hub and daemon PID bindings. The second managed job stayed queued until finish returned successful cleanup, then exited zero. The native keeper exited zero.
- A harmless owned helper named simctl triggered unmanaged audit output; the warning cleared after that process exited. Two unrelated unreadable host processes remained correctly marked as incomplete inspection.
- Native menu accessibility inspection timed out, so no visual menu-layout claim is made. UI state logic passed its tests.
- The fresh verification device was verified shut down and deleted through its own managed job after the legitimate ExplorerDex job finished. The prebooted device remained booted. No other user's process or device was stopped.

## Wat Kham interactive report

The user supplied the 06:25–06:50 local report of an external T3 daemon waiting behind hold/run, client request timeouts, and standalone boot cleanup preventing interactive use. Extend the supported native session route, not T3. Read-only simulator queries now avoid exclusive acquisition; dedicated helpers are discoverable in doctor; runner xcodebuild admission validates every destination and excludes host-wide modes. The supported client path is the absolute launcher and pinned flags from device_open, inside the native session. Bare PATH mutable commands remain outside that owner and must not be nested as another run.

Whole-change review found and closed a generic-build classification bypass and mixed metadata/host-operation bypass. The positive query grammar and shared positional destination validator apply to audit and admission.

## Final interactive verification

The final serial suite passed 178 tests. The installed release CLI matches the packaged binary by SHA-256. Doctor identifies both dedicated T3 helpers and prints the native session recipe. Read-only shim inventory remained responsive inside the held native session.

On the requested Wat Kham UUID, device_open and app launch succeeded. Plain press and snapshots reached the XCTest runner but exposed a separate null-address SIGSEGV in Date.>= during system-modal inspection. No T3 or runner sources were changed. The documented supported one-millisecond longpress workaround and plain screenshots passed three cycles with Booted verified after each. Warm interactions took under one second; screenshots took 1.24–1.56 seconds.

Agent-device close and T3 shutdown completed, then explicit settlement returned zero and the keeper exited zero. Wat Kham was Shutdown and the prebooted simulator remained Booted. Exact plain-press/snapshot verification remains limited by the independent pinned-runner crash documented under docs/troubleshooting.
