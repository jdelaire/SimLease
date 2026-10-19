# Crash limits and disposable simulator recovery

The user approved stopping repeated crashes, a single reboot retry for boot or service failures, and replacement of unhealthy disposable devices after work has finished. T3 and its installed tools remain unchanged. Persistent and borrowed simulator data must be preserved.

## Crash protection

Managed scopes record bounded, durable intervals for initially shut-down devices they own. A report reader parses macOS `.ips` reports using crash event time, process launch time, simulator UUID and executable build identity. Incident IDs prevent duplicate counting. Two matching crashes within 120 seconds block further work on that UUID. Evidence survives acknowledgment and spans separate jobs, including reports delivered after a job ends.

During a terminal scope, a newly triggered block cancels only its journaled child group when the triggering incident belongs to that scope. Existing cleanup shuts down owned devices. The result is nonzero even if a child catches termination. Delayed reports from an older scope block the next admission without canceling unrelated current work. Borrowed and keep-running devices are not automatically interrupted.

Native sessions retain their running journal and require explicit external settlement. A crash block rejects new unsafe bound mutations while allowing inventory, termination, shutdown and session finish. It does not kill shared helpers, close streams or attest settlement. Absolute native calls cannot be intercepted by PATH; the session owner must respond to warnings. Report delivery can be delayed, so this reduces repeated crashes without promising immediate popup suppression.

## Device recovery

`simlease device create --name NAME --type TYPE --runtime RUNTIME --disposable` creates a fresh registered disposable device under the lane and prints JSON. Existing devices cannot be silently enrolled.

`simlease device repair --device UUID` requires an initially Shutdown, unpaired target and no unfinished managed scope. It checks boot completion, shuts down, and retries boot once after infrastructure failure. A healthy boot does not clear an app crash block. `--acknowledge-crashes` explicitly permits another attempt while retaining prior evidence.

If both boot attempts fail, only an exact registered disposable device may be replaced. A replacement uses the same runtime and device type, is verified healthy and Shutdown before deleting the original, and is returned as a new UUID. Commands and T3 references are never rewritten. App or test-runner crashes alone never justify replacement. Failed replacement verification preserves the original.

Every recovery mutation is bracketed by a durable transaction. Interrupted or timed-out mutations remain quarantined and block regular jobs, cleanup and generic recovery. Resume requires `device repair --device UUID --settled`, an explicit attestation that prior recovery commands and background operations finished. The transaction records replacement identity before deletion and revalidates provenance, fingerprints, pairing and states at the destructive boundary. Missing or corrupt provenance protects the device. An interruption before recording a newly created UUID may leave an orphan but never authorizes deleting an unidentified device.

## Verification

Recovery can be abandoned with `device recover --settled` after every recorded existing device is Shutdown. This preserves all devices and records blocks before releasing the transaction. The original boot-attempt budget is durable across interruption. A successful replacement retires the deleted UUID's active block without deleting incident history.

Tests exercise report attribution and time parsing, duplicate and delayed reports, binary changes, persistent crash blocks, terminal cancellation and native teardown, borrowed protection, reboot limits, original preservation, replacement order and interrupted transactions. Mac package checks run serially. Live verification uses newly created disposable devices through installed SimLease and never provokes real crashes or modifies existing devices.
