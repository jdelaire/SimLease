# Crash recovery implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Limit repeated simulator app crashes and recover explicitly disposable devices without deleting persistent data.

**Architecture:** Add a report reader and durable crash store to the managed job lifecycle. Add an independent device management service with a durable recovery transaction and CLI commands. Reuse the existing host lane and process-group cleanup.

**Tech stack:** Swift 6, Foundation, Darwin, CryptoKit, XCTest, simctl.

**Spec:** `docs/superpowers/specs/2026-10-19-crash-recovery-design.md`

## Constraints

- Keep T3 source, app, launchers, pinned tools and live userdata untouched.
- Preserve unrelated `.vscode/` and all existing device data.
- No code comments. Meaningful logic tests only. Run package checks serially.
- All real simulator operations go through installed SimLease with declared targets.
- Native work always requires explicit settlement; uncertain cancellation stays quarantined.

## Review focus

- Delayed reports from another job cannot cancel the current job.
- Crash blocks must not break native termination or settlement.
- Healthy boot does not prove an app crash fixed.
- Recovery interruption cannot bypass provenance or delete the original early.
- Ambiguous command timeout remains quarantined rather than triggering retries.

## Tasks

1. [x] Add crash report fixtures and failing attribution, deduplication, time-window and history tests. Implement `SimulatorCrashReport`, `CrashReportSource` and `CrashLoopStore`.
2. [x] Add owned cancellation and native teardown tests. Integrate polling into `TaskProcessRunner` and `SimulatorTaskService`, admission checks into native/nested paths, and health diagnostics into status/doctor.
3. [x] Add recovery tests with a stateful device fixture. Implement `SimulatorDeviceManaging`, disposable registry, durable repair transaction, bounded reboot and verified replacement in `DeviceRepairService`.
4. [x] Add parser/CLI tests and device create/repair commands. Reject nested recovery and preserve explicit settlement semantics.
5. [x] Run serial tests, request read-only review, fix findings, package and install. Verify installed diagnostics. Run the fresh-device smoke check only when existing jobs release the lane.
6. [x] Update README and monitor instructions. Commit the single change on main and push, preserving unrelated files.

## Execution record

- Baseline serial suite passed with 178 tests. Final suite passed with 208 tests: 132 core, 46 CLI, 30 menu.
- Regression tests were observed failing for delayed old-report cancellation, same-batch cancellation, changed replacement provenance, reset retry budget, retired device warning, signaled mutation and malformed pairing inventory, then passed after fixes.
- Read-only Sol 6.1 at extra-high reasoning reviewed the design and implementation. All Critical and Important findings were resolved.
- Release package and installer fixture passed. Installed CLI SHA-256 matches the release artifact. All four shims and the restarted SimLease menu were verified.
- Ruling: repair stays an explicit command, rather than booting every build target or rewriting UUIDs inside arbitrary scripts. Automatic replacement occurs only within that recovery operation after two proven boot failures.
- Ruling: native health blocks preserve session settlement and never terminate shared daemons. Existing daemon requests and delayed reports limit immediate popup prevention.
- Ruling: crash scope identifiers are independent from task authorization tokens so diagnostic JSON does not expose that capability.
- A live smoke check waits for an idle lane and otherwise defers. It never preempts another project's active native session.
