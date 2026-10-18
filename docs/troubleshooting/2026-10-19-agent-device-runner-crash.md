# Agent-device runner crash during modal inspection

Observed on 2026-10-19 with T3's pinned agent-device 0.21.25, Xcode 27.2 build 27B5038j, and the Wat Kham iOS 27.2 simulator.

The managed native session admitted the dedicated hub and daemon. The runner started, published its listener, accepted a snapshot command, and activated the foreground app. Its XCTest process then crashed with `EXC_BAD_ACCESS`, `SIGSEGV`, and a null-address access.

The crash stack included:

```text
static Date.>= infix(_:_:)
RunnerTests.firstBlockingSystemModal(in:deadline:)
RunnerTests.resolveBlockingSystemModal(deadline:)
RunnerTests.blockingSystemAlertSnapshot(deadline:)
```

The pinned source location is `RunnerTests+SystemModal.swift:82`, at `Date() >= deadline`. Xcodebuild returned 65. This differs from a SimLease admission failure or a daemon request waiting for the lane. It does not establish the underlying cause of the runner's memory failure.

No T3 source, app bundle, launcher, tool source, or host configuration was patched. No runner cache was deleted.

## Verified coordinate interaction workaround

Start the managed native session with dedicated helper bindings, wait for readiness, and call `device_open`. Use its exact absolute launcher and every returned device/config/session flag.

Use a one-millisecond positional long press for coordinate taps:

```text
ABSOLUTE_LAUNCHER longpress X Y 1 RETURNED_DEVICE_CONFIG_SESSION_FLAGS
ABSOLUTE_LAUNCHER screenshot OUTPUT.png RETURNED_DEVICE_CONFIG_SESSION_FLAGS
```

Replace coordinates with the visible target. Do not add settle, verify, overlays, or recording to this workaround. Those paths can enter other runner inspection code. Plain `press`, normal snapshots, and raw snapshots still encounter the modal inspection failure in this environment.

Three native interaction/screenshot cycles completed while the device remained Booted. The first long press took 9.29 seconds while starting the runner. Warm long presses took 0.60 and 0.69 seconds; screenshots took 1.24–1.56 seconds.

Close the agent-device session and finish native capture work before settlement. The verification session owned the initially shut-down device, so it closed the T3 device with `shutdown: true`, then completed `simlease session finish ... --settled`. The keeper exited zero, Wat Kham was Shutdown, and the unrelated prebooted simulator remained Booted.
