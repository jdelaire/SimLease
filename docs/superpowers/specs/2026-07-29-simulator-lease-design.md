# System-wide CoreSimulator Lease Design

**Date:** 2026-07-29

**Status:** Approved for implementation planning

**Product:** SimLease, a standalone macOS menu-bar application with bundled CLI
tools

**Scope:** One developer Mac, all Codex threads and terminal sessions

## 1. Summary

CoreSimulator is a shared macOS service. Concurrent `xcodebuild`, `simctl`, and
AXe operations from separate projects or Codex threads can interfere even when
they target different simulator devices. SimLease is a standalone macOS
menu-bar application with bundled command-line tools. It serializes those
commands through one system-wide lease and exposes the current owner in a
compact menu-bar surface.

SimLease has no source or runtime dependency on AnimAtlas, ExplorerDex, or any
other client project. The lease is automatic for Codex and terminal commands
that resolve through the installed PATH shims. Xcode's GUI does not resolve
commands through those shims, so manual Xcode validation uses an explicit
`simlease hold` command.

## 2. Goals

- Allow only one CoreSimulator interaction lane on the Mac.
- Cover relevant `xcodebuild`, every `xcrun simctl`, and every AXe command.
- Wait for a busy lease for at most 20 minutes.
- Identify the owning Codex thread, project, command, and elapsed time.
- Show waiting threads without touching CoreSimulator.
- Release the lease automatically when a command exits or is interrupted.
- Preserve the wrapped command's exit status.

## 3. Non-goals

- Coordinating multiple Macs
- Adding SimLease to an iOS application's targets or source tree
- Modifying CoreSimulator, Xcode, AXe, or application source
- Replacing Xcode's test runner or selecting simulator devices
- Guaranteeing strict FIFO scheduling between waiting processes
- Force-releasing an active lease from the menu bar
- Recording long-term usage history, analytics, or notifications
- Automatically intercepting Xcode GUI actions

## 4. Command-line architecture

### 4.1 Installed commands

A small system tool provides:

- `simlease`: lease acquisition, status, manual hold, and thread naming
- `xcodebuild`: PATH shim that conditionally delegates through `simlease`
- `xcrun`: PATH shim that delegates `simctl` through `simlease`
- `axe`: PATH shim that delegates every AXe command through `simlease`

The shim directory is placed before the original tools in login-shell and Codex
PATH configuration. Each shim resolves the underlying executable while
excluding the shim directory, preventing recursion.

### 4.2 Protected command rules

The `xcodebuild` shim acquires the lease when either condition is true:

- the action is `test`, `test-without-building`, or `build-for-testing`; or
- a destination argument targets an iOS, watchOS, tvOS, or visionOS simulator.

Build-only commands for generic or physical-device destinations pass through
without the lease.

The `xcrun` shim acquires the lease whenever its selected tool is `simctl`.
This includes read-only `simctl` commands because they still connect to the
shared CoreSimulator service. Other `xcrun` tools pass through.

The `axe` shim acquires the lease for every command.

### 4.3 Reentrancy

While it owns the lease, `simlease` sets `SIMLEASE_HELD=1` for its child
process. A protected command invoked by that child recognizes the marker and
executes without attempting to acquire the same lease again.

## 5. Lease behavior

### 5.1 Lock authority

One advisory `lockf` lock under `~/Library/Caches/SimLease/` is the sole
authority for ownership. Process IDs and metadata are informational and never
override the lock.

`lockf` ties ownership to the holder process, so normal exit, crashes, and
signals release the lock without a separate unlock operation.

### 5.2 Waiting

When the lease is busy:

1. The wrapper writes its waiter metadata atomically.
2. It waits for the lock for up to 20 minutes.
3. Every 30 seconds, it prints the current owner and elapsed time.
4. On acquisition, it removes its waiter record and becomes the owner.
5. On timeout, it removes its waiter record and exits with status `75`.

The menu orders waiters by their recorded wait start. This is a display order,
not a strict execution guarantee; `lockf` decides which blocked process
acquires the released lock.

### 5.3 Child execution and signals

After acquiring the lease, the wrapper writes owner metadata atomically and
starts the underlying command. Signals are forwarded to the child. The wrapper
waits for the child, removes its metadata, and returns the child's exact exit
status.

If metadata is stale or malformed, status surfaces report the mismatch. They do
not kill a process, delete a lock, or claim that the lease is free.

### 5.4 Manual Xcode use

Before starting a simulator run from Xcode's GUI, the developer runs:

```sh
simlease hold --title "Manual Xcode" --project "<project>"
```

The command waits under the same 20-minute policy, prints the acquired state,
and holds the lease until `Ctrl-C`. Xcode work starts only after acquisition and
stops before the hold command is released.

This is an explicit operating rule because PATH shims cannot intercept Xcode
GUI actions.

## 6. Ownership metadata

The owner record contains:

- holder PID
- acquisition timestamp
- working directory
- derived project name
- wrapped executable and arguments
- source type: Codex, terminal, or manual Xcode
- Codex thread ID when `CODEX_THREAD_ID` exists
- registered thread title when available

Each waiter record contains the same identity fields plus its wait timestamp.
Arguments are stored for local display only and must not include environment
variables.

### 6.1 Codex thread identity

Codex provides `CODEX_THREAD_ID` to commands, so thread identity is captured
automatically. The environment does not reliably provide the human-readable
thread title.

`simlease name "<thread title>"` stores an optional local mapping for the
current `CODEX_THREAD_ID`. The displayed identity resolves in this order:

1. registered thread title
2. shortened `CODEX_THREAD_ID`
3. `Terminal · <project>` when no Codex ID exists

Manual holds display `Manual Xcode · <project>`.

Missing title registration never blocks lease enforcement.

## 7. Menu-bar ownership surface

A minimal native macOS status application launches at login and reads only
SimLease status. It never invokes CoreSimulator.

### 7.1 Menu-bar states

- **Free:** green indicator and `Simulator · Free`
- **Leased:** amber indicator and current elapsed time
- **Metadata error:** red indicator when lock state and readable metadata do not
  agree

### 7.2 Popover content

When leased, the popover shows:

- owner thread title or shortened thread ID
- project and source type
- abbreviated command
- elapsed ownership time
- waiting threads ordered by wait start

When free, it shows `Simulator available`. When metadata is inconsistent, it
shows the exact local error and suggests `simlease status`; it offers no
force-release action.

The first version includes only `Copy details` and `Refresh`. It has no history,
notifications, preferences, or destructive controls.

### 7.3 Status data flow

The app refreshes through `simlease status --json`. That command probes the
advisory lock non-destructively, reads owner and waiter metadata, and emits one
stable JSON response. It never calls `simctl`, AXe, or `xcodebuild`.

## 8. Installation

Installation creates:

- the `simlease` executable and three shims in one user-owned bin directory
- `~/Library/Caches/SimLease/` for lock and ephemeral metadata
- the menu-bar application
- a user LaunchAgent for login startup
- the required PATH entry for new login shells and Codex processes

Installation must be idempotent. It preserves existing PATH content and reports
the resolved underlying executables. Existing Codex processes must be restarted
before they inherit the new PATH.

Uninstallation removes only files installed by SimLease. It does not delete
simulators, runtimes, Xcode data, application data, or unrelated shell
configuration.

## 9. Failure behavior

- Busy beyond 20 minutes: exit `75` and identify the last observed owner.
- Wrapped command failure: return its exact exit status.
- Signal while waiting: remove waiter metadata and exit for that signal.
- Signal while running: forward it to the child; `lockf` releases ownership when
  the holder exits.
- Missing underlying executable: fail before lease acquisition with a clear
  resolution error.
- Unwritable cache directory: fail closed; do not run protected command.
- Invalid metadata: keep lock authority, show an error, and avoid destructive
  cleanup.

## 10. Verification

### 10.1 Deterministic tests

Use fake underlying executables and a temporary lease directory to verify:

- protected and pass-through command classification
- one holder at a time across concurrent processes
- reentrant child invocation
- waiter creation and cleanup
- 20-minute timeout behavior through an injected shorter test timeout
- 30-second reporting through an injected shorter test interval
- exact child exit-code propagation
- signal forwarding and lock release
- malformed and stale metadata reporting
- thread-title resolution and ID fallback
- stable `status --json` output

### 10.2 Menu-bar tests

- Free, leased, waiting, and metadata-error states render from fixture JSON.
- Long thread names and commands truncate without hiding project or elapsed
  time.
- Missing titles show shortened thread IDs.
- The app remains read-only and exposes no force-release control.

### 10.3 Real smoke test

After deterministic tests pass:

1. Start one manual hold.
2. Run a read-only `xcrun simctl list` through the shim.
3. Confirm it waits and the menu bar shows owner plus waiter.
4. Release the hold.
5. Confirm `simctl list` runs, returns its native status, and the menu returns
   to Free.

No simulator device, runtime, cache, or test result is deleted during this
smoke test.

## 11. Acceptance criteria

- Concurrent protected commands cannot hold the global lease together.
- Protected Codex and terminal commands use the lease automatically after PATH
  installation and process restart.
- The current Codex thread ID always appears when provided; a registered title
  replaces the shortened ID.
- Busy commands wait no longer than 20 minutes and report ownership every 30
  seconds.
- Menu-bar state identifies owner, elapsed time, and waiting threads without
  contacting CoreSimulator.
- Manual Xcode validation can reserve the same lane with `simlease hold`.
- Wrapped exit statuses and interrupt behavior remain intact.
- No destructive simulator operation is part of installation, status, testing,
  or normal lease cleanup.
