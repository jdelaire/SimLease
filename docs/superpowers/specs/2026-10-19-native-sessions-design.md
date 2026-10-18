# Explicit native sessions and activity alerts

Keep T3 Nightly and its installed files unchanged. Native T3 and MCP calls use an explicit SimLease reservation across the whole workflow. No custom T3 build or automatic native interception is part of this change.

`simlease session begin --device UUID ... --title TITLE --project PROJECT` runs a foreground keeper. It emits one JSON ready record only after acquiring the host lane and persisting device ownership and child identity. Declare all devices before opening them. The ready record identifies the session and devices initially shut down.

`simlease session finish ID --settled` is the caller's explicit attestation that native commands, daemon requests, background work and capture streams have finished. It persists an acknowledgment bound to the session ID and random task token, then waits for verified cleanup. It does not establish settlement merely by observing a CLI exit or T3 `device_close(shutdown:false)`.

Cancellation or keeper death without acknowledgment retains an unresolved native journal. Recovery and new jobs cannot shut down devices or clear that journal until explicit settlement. A matching durable acknowledgment remains valid if the keeper dies before recording settlement. Unknown process ownership stays blocked. Successful cleanup removes only the matching acknowledgment. Failed cleanup remains quarantined and finish returns failure.

Normal run and hold behavior stays compatible. Borrowed devices remain running. Native callers close capture streams first, shut down only devices listed as owned, then acknowledge settlement. Uncertain native cancellation remains unresolved rather than using a timeout as proof.

Activity inspection reports known simulator tool activity, unverified targets, native reservation coverage without process ownership proof, and incomplete scans separately. It uses exact kernel process identities and rechecks identity after bounded argument reads. It does not publish arguments or environment. Idle daemons, CoreSimulator services, inventory queries and explicit Android, physical-device and macOS targets are excluded.

Inspection is advisory and never grants a bypass or triggers cleanup. Five-second menu snapshots can miss short-lived commands and cannot prove a persistent daemon is idle. Empty results do not establish universal coverage. The menu and doctor share one audit implementation; status scans only with `--audit`.

Validation covers acknowledgment crashes and stale tokens, failed cleanup, competing jobs, PID reuse, metadata queries, target exclusions, partial inspection and warning clearing. Live verification uses an isolated owned simulator under a native session, preserves prebooted devices and leaves Nightly installed.

## Explicit helper binding

Live verification found that stock Nightly's dedicated device hub inherits SimLease shims and calls `xcrun simctl` internally. An unbound reservation would self-wait. The supported stock-app route is repeatable `--client-pid` binding for dedicated native helpers, with kernel start identities captured before lane wait and rechecked before readiness. It changes no T3 files or processes.

Only supported simctl actions with exact positional declared UUIDs, plus read-only inventory, may join that reservation. Aliases, other device sets, host-wide actions and unknown protected tools fail promptly. An admission flock drains live shim wrappers before settlement and prevents new admission while finish holds its exclusive lock. It cannot prove daemon or orphaned-child settlement. Registered roots are never killed. Audit applies the same validator before treating their descendants as managed.

Whole-change Sol 6.1 review approved this narrow extension subject to identity, token, phase, acknowledgment and lock revalidation. Helper binding covers all requests through the helper, so callers must use trusted dedicated roots and coordinate other threads.

## Interactive runner admission

Dedicated helpers can also run xcodebuild with every destination resolved to a declared simulator UUID. A positive metadata query grammar permits pure inspection. Host-wide operation modes, mixed unresolved destinations, duplicate destination keys, physical SDK/platform conflicts and other device sets are rejected. All bound xcodebuild invocations pass native admission, including forms outside general lease classification. Read-only simctl queries do not require exclusive acquisition or establish ownership. Doctor reports dedicated helper identities and the explicit interactive recipe.
