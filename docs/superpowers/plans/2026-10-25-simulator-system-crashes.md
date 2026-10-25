# Simulator system crash containment implementation plan

> For agentic workers: use superpowers:executing-plans. Apply test-driven development and request a final independent review.

Goal: reject further managed work on a simulator after a verified critical runtime-service crash, without claiming to repair Apple's runtime.

Architecture: distinguish device quarantine from permission to cancel a job. Runtime reports use a strict simulator coalition and launchd_sim parent. Only existing owned-scope attribution permits job cancellation and device cleanup.

Tech stack: Swift, Foundation, XCTest, host-only fake devices.

Spec: the user-provided PosterBoard report and the constraints below.

## Constraints

- Preserve active jobs, simulator data, crash reporting, and explicit native settlement.
- Never acknowledge a crash until its cause is fixed.
- No simulator boots are needed for this change.
- Write no code comments. Preserve unrelated .vscode files.
- Keep old crash history readable.
- Runtime failures cannot be guaranteed away. Containment must state that limit.

## Reviewed choices

The first Sol 6.1 high review approved strict parsing and first-event critical-service quarantine. Subsequent investigation found seven crashes with no matching owned scope, making scope-only quarantine insufficient. The second review approved independent quarantine and status/doctor ingestion, requiring durable cancellation receipts, restart-safe scan progress, safe warm reaping, and accurate menu wording. The alternative of resetting wallpaper or erasing the simulator lacks a confirmed diagnosis and would destroy evidence.

## Task 1: recognize runtime reports

Files: Sources/SimLeaseCore/SimulatorCrashReport.swift, Tests/SimLeaseCoreTests/CrashLoopTests.swift.

- [x] Add a sanitized two-object PosterBoard fixture and tests for exact UUID, event time, stable signature, and host/malformed/conflicting identity rejection. Run and observe rejection before the fix.
- [x] Permit runtime fallback only when no device-data path exists, with exact launchd_sim parent and an anchored simulator coalition UUID.
- [x] Classify PosterBoard and SpringBoard only with matching process, Apple bundle ID, executable suffix, and verified runtime attribution. Use optional isCriticalSystemService for old-history compatibility.
- [x] Confirm an installed app named PosterBoard stays ordinary, and legacy JSON decodes.

## Task 2: quarantine safely

Files: Sources/SimLeaseCore/CrashLoopStore.swift, Sources/SimLeaseCore/SimulatorTaskService.swift, Tests/SimLeaseCoreTests/CrashLoopTests.swift, Tests/SimLeaseCoreTests/SimulatorTaskServiceTests.swift.

- [x] Test first critical-event blocking, duplicate handling, persistence, acknowledgments, future and delayed reports, and unchanged ordinary-app threshold.
- [x] Quarantine critical incidents even without an owned scope. Persist per-device cancellation receipts in crash-cancellations.json, separate from history and admission blocks so legacy writers cannot erase them. Only owned launch/event-time attribution permits cancellation. Borrowed and preexisting services cannot authorize shutdown.
- [x] Test one critical report returns 70, stops only owned terminal work, prevents warm retention and rejects another launch. Preserve native settlement.

## Task 3: inspect outside jobs

Files: Sources/SimLeaseCLI/CLI.swift, Sources/SimLeaseCLI/CoverageDoctor.swift, Tests/SimLeaseCLITests/DeviceCLITests.swift, README.md.

- [x] Add status and doctor tests using a temporary report directory and cache. Detection must work without a running scope and must preserve active task metadata.
- [x] Ingest bounded crash reports in status and doctor before showing blocks. The menu already polls status every five seconds. Persist scan progress only after ingestion succeeds; skip unchanged reports across processes. Unowned blocks cannot accelerate warm reaping.
- [x] Update diagnostics and README to explain first-event critical quarantine, ownership limits and explicit recovery.

## Review focus

- A malformed device path must never fall through to coalition attribution.
- A borrowed or preexisting process must never authorize cancellation.
- A late report must not replace a current owned cancellation block unsafely.
- Repeated independent status processes must keep ingestion and history bounded.
- Runtime/device changes are not evidence that an earlier crash was fixed.

## Verification and delivery

- [x] Run meaningful regression tests after their red/green cycle, then swift test -j 1 and release builds.
- [x] Obtain Sol 6.1 high implementation review for bugs and performance.
- [ ] Activate through the supported installer only if it preserves active work and signed-app integrity. Verify the known failing UUID is quarantined without booting, shutting down or acknowledging it.
- [ ] Commit the single change, merge to main, push, and delete the feature branch.

## Verification record

Baseline full host suite passed. The sanitized PosterBoard fixture initially failed parsing, then parser tests passed. Critical quarantine initially failed for owned and unowned events, then all crash-store tests passed. Terminal regressions reproduced missed cancellation and incorrect cancellation from delayed reports before changing the polling rule. Status/doctor and persistent-progress regressions initially failed before ingestion was added.

The implementation reviewer found three important issues. Each received a failing regression before the fix: legacy history rewrites erased cancellation receipts, unreadable reports starved older evidence, and future events were consumed permanently. Receipts now use a separate bounded file, failed reads receive a persistent 30-second backoff, and future events remain pending. Focused regression tests pass. Final full-suite and release-package verification follows these fixes.

An existing native destination-validation test timed out once during a full run. It passed in isolation and the following full run without changing its timeout. A further regression demonstrated that failed reads must rank behind unscanned evidence even after their retry delay expires. That test failed before scan ordering was corrected. Final verification uses one build job to limit host load.

Final full host suite: 293 tests passed, 0 failures, using swift test -j 1. This includes all four review regressions and unchanged native-session tests.

The release CLI and menu app built successfully. The packaged app passed strict signature verification. Supported local activation and quarantine verification are delegated to Sol 6.1 high; no simulator mutation is part of activation.
