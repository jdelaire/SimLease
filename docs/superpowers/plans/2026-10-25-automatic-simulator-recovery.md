# Automatic simulator recovery implementation plan

Goal: SimLease should recover idle simulator infrastructure automatically instead of asking the user to dismiss crash cards.

The user explicitly requested self-repair. Sol 6.1 high reviewed the architecture before implementation. Preserve app data, active jobs, borrowed/native work, pairings, exact UUID targets and explicit settlement. Never erase or replace persistent devices. Do not treat a successful boot as proof that app code is fixed.

## Reviewed approach

Use bounded nondestructive restart and service verification for critical infrastructure. Background Apple service crashes stay in diagnostics and do not cancel app work. App/test crashes remain independent reasons that infrastructure repair cannot clear. Deleted devices move to history after complete inventory succeeds. Unknown evidence remains conservative.

Recovery states are waiting, restarting, verifying, cooldown, recovered, action required and history. Limit recovery to two attempts per device in 24 hours, at least ten minutes apart. New incidents and process restarts do not reset the budget. Recovery uses exclusive nonblocking lane acquisition and the existing reaper lock. Recheck all task journals, process audit, availability, pairing and device identity before touching a target. Boot only with host headroom. Cooldown holds no lane.

Use the existing device recovery transaction for actual commands, including a new single nondestructive restart-and-verify path. Never enter disposable replacement from a service crash. Interrupted or uncertain operations retain the transaction and cannot settle themselves. Verify at least 120 continuous booted seconds, service liveness and absence of new critical reports, followed by verified shutdown and final scan. Resolve only the expected infrastructure signature/generation, without advancing application acknowledgment timestamps.

## Steps

- [x] Add positive crash classes, legacy metadata enrichment and selective independent block reasons. Test background services, installed apps with matching names, mixed app/infrastructure failures and compare-and-swap resolution.
- [x] Add durable recovery state, attempt budget and safe nonblocking maintenance. Test busy/borrowed/paired/unavailable targets, competing workers/reaper, quiet-window failure, uncertain interruption and persistent-device preservation.
- [x] Add production health probes supported by static runtime evidence. Missing or unverifiable service health cannot count as success.
- [x] Trigger maintenance from the menu minute loop and before blocked CLI admission, retaining exact UUID and lane ownership.
- [x] Replace automatic-infrastructure manual cards with recovery progress; group background diagnostics; move deleted-device alerts to history only on complete inventory. Capture before/after host-rendered menu evidence.
- [ ] Run meaningful regression tests, full host suite, release builds and Sol 6.1 high implementation review.
- [ ] Commit, merge to main, push, remove feature branch, install through the supported installer and verify live behavior without interrupting jobs.

## Implementation boundaries

Crash classification and block reasons belong in the core crash store. Recovery metadata belongs in a separate file so legacy writers cannot erase it. Device commands retain the existing recovery journal recognized by older CLI processes. Status and doctor report state; maintenance performs actions. No shared-state lock is held during device commands or observation. No automatic arbitrary-command replay.

## Review corrections

Sol 6.1 high found seven issues in the first implementation review. Cleanup now rechecks native activity, pairing and identity and preserves uncertainty. Budgets are reread under exclusive ownership; protected targets cannot starve eligible devices. Per-signature generations cannot regress on delayed evidence. Unresolved app cancellation takes priority over infrastructure receipts. Malformed or unknown report bytes stay pending, while proven unrelated host reports can checkpoint. Host-only regressions cover each sequence. Maintenance bypasses only its own admission-spacing timestamp; CPU, memory and recovery limits remain enforced. Observation uses monotonic elapsed time.

Final review also verified standalone shim admission shares recovery preflight while nested/native calls remain excluded. A service-verification failure no longer counts toward the two actual boot failures required for any later manual disposable replacement. The retained-transaction and explicit-settlement regression reproduced deletion before the fix and preserves the original afterward. Final host suite: 320 passing tests. Sol 6.1 high cleared the implementation and final counter delta.

## Mixed-version deployment follow-up

Live verification found older CLI writers removing incident classifications from shared crash history. Classification proof now uses a dedicated file, matched by all six immutable report fields and bounded to 512 retained incidents. A separate migration checkpoint reuses the same scan budget to classify only retained, previously consumed reports. It cannot replay evicted incidents, acknowledge crashes or generate cancellation events. Missing raw evidence remains unclassified.

Failure-window regressions verify that policy reconciliation survives a metadata-only partial commit and that old classification proof remains until history eviction commits. New incident history commits before proof pruning, and scan/migration progress commits only after proof persistence.
