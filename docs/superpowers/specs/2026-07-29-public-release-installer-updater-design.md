# SimLease Public Release, Installer, and Updater Design

## Goal

Publish SimLease as a polished public GitHub project with a signed and notarized
Apple Silicon release, a verified user-level installer, an explicit
`simlease update` command, and a listing in the `jdelaire` profile repository.

The initial public version is `0.1.0`.

## Product Decisions

- Repository: `https://github.com/jdelaire/SimLease`
- Visibility: public
- License: MIT
- Minimum system: macOS 15
- Architecture: Apple Silicon (`arm64`) only
- Update policy: explicit `simlease update` only
- Release automation: tag-driven GitHub Actions
- Trust: Developer ID signing, Apple notarization, stapling, SHA-256, and
  Gatekeeper validation
- Distribution: GitHub Releases

There is no background update check, menu-bar update notification, Homebrew
tap, Sparkle integration, Intel build, privileged installer, or automatic
simulator cleanup.

## Public Repository

GitHub repository metadata is:

- Name: `SimLease`
- Description: `Coordinate shared iOS Simulator access across agents and
  terminal sessions, with safe stale-simulator cleanup.`
- Topics:
  - `macos`
  - `swift`
  - `swiftui`
  - `ios-simulator`
  - `coresimulator`
  - `codex`
  - `automation`
  - `developer-tools`
- Issues: enabled
- Wiki: disabled
- Projects: disabled
- Default branch: `main`

The public tree includes an MIT `LICENSE`, source code, tests, release workflow,
installer scripts, and development documentation. Build output, release
archives, local credentials, caches, and notarization material remain ignored.

Before the first push, inspect every staged path and scan the worktree and
reachable history for credentials or private artifacts. Do not stage unrelated
files from adjacent repositories.

## Public README

The README leads with the problem SimLease solves, then documents:

1. macOS 15 and Apple Silicon requirements
2. one-line installation
3. the menu-bar app and automatic PATH shims
4. the agent coordination contract
5. manual Xcode reservation
6. stale-simulator cleanup safety
7. `simlease update`
8. uninstall behavior
9. development, testing, and release commands

Internal validation chronology is replaced by durable capability and testing
information. The README must not imply that status checks alone acquire the
lease or that cleanup is automatic.

## Version Contract

The app and CLI expose the same semantic version:

- `CFBundleShortVersionString` is `0.1.0`
- `CFBundleVersion` is a monotonically increasing release build number
- `simlease --version` prints `simlease 0.1.0`

The release workflow derives the expected semantic version from a `vX.Y.Z`
tag and fails if it does not match the source version. Drafts and prereleases
are never selected by the installer or updater.

Version comparison accepts only three nonnegative numeric components. Invalid
local or remote versions stop the update without changing the installation.

## Release Bundle

A successful `v0.1.0` workflow publishes:

```text
SimLease-0.1.0-arm64.zip
SimLease-0.1.0-arm64.sha256
```

The archive contains:

```text
SimLease.app/
bin/simlease
install.sh
install-release.sh
Resources/com.jdelaire.simlease.plist
```

The app bundles the same CLI under `Contents/Resources/bin/simlease`. All Mach-O
executables are arm64.

The workflow:

1. checks out the exact tag;
2. verifies tag and source versions match;
3. runs the complete Swift and shell test suite;
4. builds release app and CLI artifacts;
5. imports the Developer ID certificate into an ephemeral keychain;
6. signs nested executables first, then the application with hardened runtime;
7. verifies the signature;
8. submits the app archive for notarization;
9. requires an accepted notarization result;
10. staples and validates the ticket;
11. creates the final archive and SHA-256 file;
12. publishes a non-draft GitHub Release with generated release notes.

Signing and notarization credentials exist only as GitHub Actions secrets.
Temporary keychains and decoded credential files are removed even after a
failure.

## Bootstrap Installer

The public install command is:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/jdelaire/SimLease/main/scripts/install-release.sh \
  | zsh
```

This is the only trust-on-first-use script. It performs no privileged action and
does not use `sudo`.

The bootstrap installer:

1. requires macOS 15 or newer and `arm64`;
2. queries the latest stable release for `jdelaire/SimLease`;
3. downloads the exact archive and checksum into a private temporary directory;
4. verifies the SHA-256;
5. extracts into the temporary directory;
6. confirms the archive contains only the expected release layout;
7. verifies every required executable is arm64;
8. runs strict code-signature validation on the app;
9. requires Gatekeeper acceptance;
10. invokes the downloaded, versioned `install.sh`;
11. removes its temporary directory on every exit path.

Network, JSON, missing-asset, checksum, archive-layout, architecture, signing,
and Gatekeeper failures occur before installation begins.

Test-only environment overrides may replace the GitHub API and download roots.
Production defaults remain fixed to `jdelaire/SimLease`.

## Transactional User-Level Installation

Installation remains entirely under the current user:

```text
~/Applications/SimLease.app
~/.local/lib/simlease/simlease
~/.local/lib/simlease/install-release.sh
~/.local/lib/simlease/shims/
~/Library/LaunchAgents/com.jdelaire.simlease.plist
```

The installer preserves the marked `.zprofile` PATH block and refuses to
overwrite unrelated paths inside the SimLease-owned shim directory. It never
modifies the preserved underlying AXe or any executable elsewhere on PATH.

Before replacement, it validates the complete incoming release and stages all
files on the destination filesystem. It then:

1. saves recoverable backups of the currently installed app, CLI, updater, and
   LaunchAgent;
2. atomically places the staged files where possible;
3. creates or refreshes only SimLease-owned shims;
4. writes the LaunchAgent atomically;
5. refreshes the marked PATH block idempotently;
6. restarts or bootstraps the LaunchAgent;
7. verifies the installed app, CLI version, updater, and LaunchAgent;
8. removes backups only after verification succeeds.

If a replacement or verification step fails, the installer restores the prior
installation and LaunchAgent before returning failure.

The installer never deletes SimLease cache metadata, simulator devices,
simulator runtimes, Xcode data, unrelated applications, unrelated
LaunchAgents, or unrelated shell configuration.

## Explicit Updater

`simlease update` invokes the verified updater installed at:

```text
~/.local/lib/simlease/install-release.sh
```

The updater contacts GitHub only after the explicit command. It compares the
embedded CLI version with the latest stable release:

- same version: print that SimLease is current and exit successfully;
- newer version: use the complete bootstrap verification and transactional
  installation flow;
- older remote version: do not downgrade;
- invalid version, unavailable network, or failed verification: print the
  concrete error and leave the installation untouched.

Replacing the executable does not invalidate an already running leased command:
the existing process continues from its open executable while new commands use
the new binary. Lease metadata and lock files are unchanged.

## Error Contract

- Usage errors remain exit `64`.
- Latest-release or download unavailability exits `69`.
- Integrity, signing, architecture, or transactional install failures exit
  `74`.
- A successful no-op update exits `0`.
- A successful install or update exits `0`.

Errors identify the failing stage without printing credentials, authorization
headers, temporary keychain passwords, or private-key material.

## Testing

Automated coverage includes:

- semantic-version parsing and ordering;
- `--version`;
- update command parsing and dispatch;
- current, newer, older, malformed, draft, and prerelease versions;
- release asset selection;
- failed network and missing assets;
- checksum mismatch;
- unexpected archive layout;
- non-arm64 artifact rejection;
- signature and Gatekeeper failure propagation;
- clean installation in a temporary home;
- update from an older fixture;
- same-version no-op;
- rollback after a staged replacement failure;
- idempotent reinstall;
- preserved custom AXe and unrelated PATH content;
- preserved cache and simulator data;
- LaunchAgent replacement and restart behavior;
- release archive contents and version agreement.

Tests use local fixtures and injected command runners or endpoints. They do not
contact GitHub, Apple notarization, or CoreSimulator.

Before publication:

1. run the complete Swift suite;
2. run every installation and smoke test;
3. validate shell syntax;
4. validate the GitHub Actions workflow;
5. build the arm64 release bundle locally;
6. inspect the staged git diff;
7. run credential and private-artifact scans.

After the workflow publishes `v0.1.0`, download the public assets into a clean
temporary home and verify install, status, version, same-version update, and
uninstall. Verify GitHub reports the expected release, metadata, topics,
visibility, default branch, and license.

## Publication Sequence

1. Implement and verify the installer, updater, version contract, release
   packaging, workflow, license, and public README locally.
2. Create public `jdelaire/SimLease` with the approved metadata.
3. Configure the signing and notarization GitHub Actions secrets without
   exposing their values.
4. Push the complete `main` branch.
5. Confirm local, remote, and GitHub API commit SHAs match.
6. Create and push tag `v0.1.0`.
7. Require the release workflow and public clean-install verification to pass.
8. Update `../jdelaire/README.md` under Current Playground with:

```markdown
- 🚦 **[SimLease](https://github.com/jdelaire/SimLease)**: Coordinates shared
  iOS Simulator access across agents and terminal sessions, with safe,
  explicitly confirmed stale-simulator cleanup.
```

9. Commit and push the profile change separately.
10. Verify the public profile link and release URL resolve.

No GitHub repository, release tag, profile change, or public push occurs before
the local public-safety and validation gates pass.
