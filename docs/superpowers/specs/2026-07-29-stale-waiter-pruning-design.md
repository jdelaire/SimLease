# Stale Waiter Pruning Design

## Goal

Show only processes that are still genuinely waiting for the simulator lease,
including when macOS has reused a dead waiter's PID.

## Design

`LeaseCoordinator.status()` remains the authoritative status read. After loading
waiter metadata, it asks an injected process inspector whether each PID still
belongs to the process that created the waiter. The production inspector reads
the process start time with `proc_pidinfo`.

A waiter is stale when its PID no longer exists or when the current process
started after the waiter's `waitingSince` timestamp. A one-second tolerance
accounts for timestamp precision. A lookup that cannot establish identity fails
open and keeps the waiter visible.

Stale waiter files are removed during status refresh. This repairs existing
metadata without a migration because every current waiter already stores its PID
and `waitingSince`.

## Safety

- Never terminate a process to prune metadata.
- Never alter the lease lock or owner metadata.
- Never prune when process identity is unknown.
- Preserve legitimately long waits without a time-to-live limit.
- Treat PID reuse as stale even when `kill(pid, 0)` reports a live process.

## Testing

- A free lease prunes missing and PID-reused waiters.
- A matching live waiter remains visible.
- An unknown process lookup remains visible.
- Pruned waiter JSON disappears from the metadata store.
- The system inspector recognizes the current process and an impossible PID.
- Existing lease, CLI, menu, installer, and cleanup suites remain green.

## Release

Ship as `0.1.2`. Update the CLI and bundle versions together, merge the release
PR to `main`, push tag `v0.1.2`, and let the repository Release workflow sign,
notarize, staple, checksum, and publish the GitHub assets.
