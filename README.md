# SimLease

SimLease coordinates shared iOS Simulator access across agents and terminal
sessions. Its command shims acquire one atomic lease before simulator work,
while the menu-bar app shows the owner and every waiting thread.

Simulator cleanup is separate and always explicit: SimLease inventories stale
devices and outdated runtimes, shows the exact protected and eligible targets,
then requires the generated plan ID before deleting anything.

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
restores the previous version if it fails. It never uses `sudo`.

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

## Stale simulator cleanup

Review without deleting:

```sh
simlease clean plan
simlease clean plan --json
```

Apply only the exact reviewed plan:

```sh
simlease clean apply ABC123
```

A device is eligible only when shut down and reported unused for at least 30
days. Booted devices, devices with unknown age, and devices whose data path
does not exactly match their UUID are protected. A runtime is eligible only
when Apple's dry run identifies its exact image and no booted device uses it.

Plans expire after ten minutes and can be used once. Apply rechecks the entire
inventory before processing devices first and runtimes second. Cleanup is
never automatic or scheduled.

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
zsh Tests/InstallationTests/install-release.zsh
zsh Tests/InstallationTests/package-release.zsh
```

Local packaging is ad-hoc signed. Public tag releases are Developer ID signed,
notarized, stapled, and published with a matching SHA-256 file.

## License

SimLease is available under the [MIT License](LICENSE).
