# SimLease

SimLease coordinates shared iOS Simulator access across agents and terminal
sessions. Its command shims acquire one atomic lease before simulator work,
while the menu-bar app shows the owner and every waiting thread.

Storage cleanup is separate and always explicit. SimLease reviews stale
simulators, rebuildable Xcode caches, and guarded artifacts, then applies only
the selected target IDs from a short-lived plan.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Xcode command-line tools

## Install

```sh
curl -fsSL \
  https://raw.githubusercontent.com/jdelaire/SimLease/main/scripts/install-release.sh \
  | zsh
```

The installer downloads the latest stable GitHub release and verifies its
SHA-256 checksum, arm64 architecture, Developer ID signature, and Gatekeeper
assessment before changing the current installation. Activation is staged and
restores the previous version if it fails. During an update, it stops the
running menu app and bootstraps a fresh LaunchAgent registration so the new
signed binary is actually running. It never uses `sudo`.

Restart terminal login shells and Codex after the first install so their PATH
starts with:

```text
~/.local/lib/simlease/shims
```

## Agent workflow

Run each complete simulator job inside one scope:

```sh
simlease run --device DEVICE-UUID -- /path/to/verification-script
```

The command can be an absolute executable, a PATH command, or a shell script.
Repeat `--device` for a phone and watch pair. The existing single host-wide
lane stays held until the command and its cleanup finish.

A device that was shut down when the scope started belongs to that scope.
After success, failure, or cancellation, SimLease stops the owned child process
group, shuts down those devices, and verifies `Shutdown` before admitting the
next job. Prebooted devices are borrowed and remain running. Use
`--keep-running` to explicitly retain a device started by the job.

Exact UUID destinations are inferred for protected `xcodebuild` commands.
Managed test commands disable parallel simulator cloning. Named destinations
and simulator launches hidden inside arbitrary scripts cannot establish device
ownership; declare every intended UUID on the outer scope. Nested commands
inherit a validated task token instead of acquiring another lane.

Inspect coordination and command coverage:

```sh
simlease status --json
simlease doctor --json
```

`status` reports `free`, `leased`, or `metadataError`. An unfinished cleanup
appears as an error and blocks new protected work. After a process crash,
recovery runs before the next protected job, or can be requested directly:

```sh
simlease recover
```

Recovery requires proven process ownership. A live or unverifiable owner is
never taken over. Failed cleanup retains its journal for a later retry; there
is no force-release command.

### Shell and native tool coverage

Normal `xcodebuild`, `xcrun`, `axe`, and `agent-device` lookup goes through
installed PATH shims. Nested `xcrun xcodebuild` is protected too. Absolute
executables must be placed inside `simlease run`; PATH cannot intercept them.
An inherited `SIMLEASE_HELD=1` flag alone never authorizes bypass.

For Xcode GUI or native T3/MCP device work, keep an explicit reservation open
for the entire verification session:

```sh
simlease hold --title "UI verification" --project "Project" --device DEVICE-UUID
```

Wait until `status` identifies that reservation as owner before operating the
native tool. End the reservation with Ctrl-C when verification is complete;
its owned devices are then shut down. Keep the reservation open across all
commands in the session. A native tool that ignores reservations can still
bypass coordination, so its integration must participate explicitly.

`doctor` reports missing PATH shims and known running tool processes outside
the active task ancestry. It is an audit, not an operating-system sandbox.
GUI applications already running must be restarted or configured explicitly
to inherit the installed PATH. Persistent `agent-device daemon` startup is
not wrapped in a lifetime-long lease.

Managed `agent-device` clients and daemon starts receive a PATH with SimLease
shims removed for internal tool lookup, preventing recursive lease acquisition.
Restart a daemon previously started with a shimmed PATH when its current work
finishes. Native launchers must configure the same internal tool lookup.
Daemon requests may outlive a canceled client; keep an explicit reservation
until the daemon confirms its work has finished. Client process cleanup cannot
prove that external daemon work has settled.

Name the current Codex thread so waiters can identify it:

```sh
simlease name "[Project] Simulator validation"
```

## Xcode storage cleanup

Review without deleting:

```sh
simlease clean plan
simlease clean plan --json
```

Apply only selected targets from the exact reviewed plan:

```sh
simlease clean apply ABC123 \
  --target 'derivedData:/path/from-plan' \
  --target 'DEVICE-UUID'
```

A device is eligible only when shut down and reported unused for at least 30
days. Booted devices, devices with unknown age, and devices whose data path
does not exactly match their UUID are protected. A runtime is eligible only
when Apple's dry run identifies its exact image and no booted device uses it.

Rebuildable cache thresholds are:

- temporary/custom DerivedData: 24 hours;
- Xcode previews: 7 days;
- standard DerivedData and project `.build`: 14 days.

Result bundles older than 30 days, Archives older than 90 days, and every
Device Support folder appear as guarded storage. They are never preselected
and move to Trash instead of being permanently deleted. SimLease never empties
Trash.

Plans expire after ten minutes and can be used once. Apply requires one or
more `--target` flags, rechecks fingerprints and active build paths, and skips
anything changed or newly protected. A leased simulator lane defers simulator
inventory without blocking filesystem review. Cleanup never force-releases a
lease, stops tests, deletes worktrees, or runs automatically.

## Update

```sh
simlease update
```

Updates are manual. The command uses the installed verified release bootstrap,
never downgrades, and exits successfully when already current.

## Managed paths

```text
~/Applications/SimLease.app
~/Library/LaunchAgents/com.jdelaire.simlease.plist
~/.local/lib/simlease/simlease
~/.local/lib/simlease/install-release.sh
~/.local/lib/simlease/shims/
```

The shims delegate to the next matching command on PATH, so an existing custom
AXe remains the underlying AXe.

## Uninstall

From a source checkout:

```sh
scripts/uninstall.sh
```

Uninstall removes only SimLease-managed app, agent, CLI, updater, shims, and
marked PATH block. It preserves simulator data, SimLease cache metadata, and
the underlying custom AXe.

## Development

```sh
swift test
scripts/package-app.sh
zsh Tests/InstallationTests/install-app.zsh
zsh Tests/InstallationTests/install-relaunch.zsh
zsh Tests/InstallationTests/install-release.zsh
zsh Tests/InstallationTests/package-release.zsh
```

Local packaging is ad-hoc signed. Public tag releases are Developer ID signed,
notarized, stapled, and published with a matching SHA-256 file.

## License

SimLease is available under the [MIT License](LICENSE).
