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

Before simulator testing:

```sh
simlease status --json
```

- `free`: testing may start.
- `leased`: continue work that does not need the simulator or recheck later.
- `metadataError`: stop and report the error.

The check is advisory. Normal `xcodebuild`, `xcrun`, and `axe` lookup resolves
through SimLease shims, which acquire the lease atomically. Do not bypass the
shims with absolute paths.

Name the current Codex thread so other waiters can identify it:

```sh
simlease name "[Project] Simulator validation"
```

Reserve the lane for Xcode GUI work, which PATH shims cannot intercept:

```sh
simlease hold --title "Manual Xcode" --project "Project"
```

SimLease has no force-release command.

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

Simulator testing still begins only after:

```sh
simlease status --json
```

reports `free`.

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
