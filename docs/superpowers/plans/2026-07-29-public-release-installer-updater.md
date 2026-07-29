# Public Release, Installer, and Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish SimLease as a public, signed, notarized Apple Silicon release
with a safe user-level installer and a manual `simlease update` command, then
list it on the `jdelaire` profile.

**Architecture:** GitHub Releases is the only release channel. A small
bootstrap script resolves the latest stable release, verifies its checksum,
architecture, signature, and Gatekeeper assessment, then delegates to the
bundled transactional installer. The CLI updater invokes the installed copy of
that same bootstrap script. A tag-driven GitHub Actions workflow builds, signs,
notarizes, staples, packages, checksums, and publishes releases.

**Tech Stack:** Swift 6, Swift Package Manager, zsh, GitHub Actions, Developer
ID signing, Apple notarization, macOS 15, arm64

## Public Contract

- Repository: `https://github.com/jdelaire/SimLease`
- Initial release: `v0.1.0`
- Minimum system: macOS 15 on Apple Silicon
- License: MIT
- Install command:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/jdelaire/SimLease/main/scripts/install-release.sh \
  | zsh
```

- Release assets:
  - `SimLease-0.1.0-arm64.zip`
  - `SimLease-0.1.0-arm64.sha256`
- Manual update command: `simlease update`
- Exit codes: `64` usage, `69` unavailable, `74` integrity/install failure
- No automatic update checks and no update UI.

## Safety Constraints

- Never use `sudo`.
- Never replace the preserved custom AXe target.
- Preserve simulator data, SimLease cache metadata, unrelated PATH entries, and
  unrelated LaunchAgents.
- Stage and verify a full install before replacing the current installation.
- Restore the previous installation if activation fails.
- Do not create `v0.1.0` until signing/notarization credentials are configured.
- Do not update the profile README until the public release installs
  successfully.

---

### Task 1: Add a tested semantic version and CLI version command

**Files:**
- Create: `Sources/SimLeaseCore/SemanticVersion.swift`
- Create: `Sources/SimLeaseCLI/SimLeaseBuild.swift`
- Modify: `Sources/SimLeaseCLI/CommandParser.swift`
- Modify: `Sources/SimLeaseCLI/SimLeaseCLI.swift`
- Create: `Tests/SimLeaseCoreTests/SemanticVersionTests.swift`
- Modify: `Tests/SimLeaseCLITests/CommandParserTests.swift`
- Modify: `Tests/SimLeaseCLITests/SimLeaseCLITests.swift`

- [ ] **Step 1: Add failing semantic-version tests**

Cover parsing `0.1.0` and `v0.1.0`, comparison across patch/minor/major, and
rejection of prerelease text, missing components, negative values, and
non-numeric components.

- [ ] **Step 2: Add failing parser and CLI tests**

Assert `--version` parses as `.version` and prints exactly:

```text
simlease 0.1.0
```

- [ ] **Step 3: Run focused tests and verify RED**

```bash
swift test --filter SemanticVersionTests
swift test --filter CommandParserTests
swift test --filter SimLeaseCLITests
```

- [ ] **Step 4: Implement the minimum version types**

Implement a comparable `SemanticVersion` with exactly three integer
components, optional leading `v`, and a canonical `description`.
`SimLeaseBuild.currentVersion` is `0.1.0`. Add `.version` to `ParsedCommand`,
parse only the top-level `--version`, and print the public version string.

- [ ] **Step 5: Run focused tests and verify GREEN**

```bash
swift test --filter SemanticVersionTests
swift test --filter CommandParserTests
swift test --filter SimLeaseCLITests
```

---

### Task 2: Add a tested manual update command

**Files:**
- Create: `Sources/SimLeaseCLI/UpdateRunner.swift`
- Modify: `Sources/SimLeaseCLI/CommandParser.swift`
- Modify: `Sources/SimLeaseCLI/SimLeaseCLI.swift`
- Modify: `Tests/SimLeaseCLITests/CommandParserTests.swift`
- Modify: `Tests/SimLeaseCLITests/SimLeaseCLITests.swift`

- [ ] **Step 1: Add failing update tests**

Assert:

- `update` parses as `.update`;
- the CLI invokes the configured updater with
  `--current-version 0.1.0`;
- updater stdout/stderr pass through;
- updater exit status is returned unchanged; and
- a missing updater prints reinstall guidance and returns `69`.

Use an injected `UpdateRunning` test double; do not launch a real updater from
unit tests.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --filter CommandParserTests
swift test --filter SimLeaseCLITests
```

- [ ] **Step 3: Implement update dispatch**

Add `UpdateRunning` and a production `ProcessUpdateRunner`. Resolve the
installed updater at:

```text
~/.local/lib/simlease/install-release.sh
```

The production runner launches `/bin/zsh` with the updater path and
`--current-version 0.1.0`, inheriting standard input/output/error. Keep
dependency injection inside `CLIConfiguration`.

- [ ] **Step 4: Update CLI usage**

The top-level usage line becomes:

```text
Usage: simlease <status|name|hold|clean|update|--version>
```

- [ ] **Step 5: Run focused tests and verify GREEN**

```bash
swift test --filter CommandParserTests
swift test --filter SimLeaseCLITests
```

---

### Task 3: Make the local installer transactional

**Files:**
- Modify: `scripts/install.sh`
- Modify: `scripts/uninstall.sh`
- Create: `Tests/InstallationTests/install-app.zsh`

- [ ] **Step 1: Add a failing isolated-home installer test**

Run the installer with a temporary `HOME` and explicit source overrides for the
CLI, app, updater, and LaunchAgent plist. Assert it installs:

```text
~/.local/lib/simlease/bin/simlease
~/.local/lib/simlease/install-release.sh
~/Applications/SimLease.app
~/Library/LaunchAgents/com.jdelaire.simlease.plist
~/.local/lib/simlease/shims/{simlease,xcodebuild,xcrun,axe}
```

Assert the custom AXe target and unrelated shell profile content are unchanged.

- [ ] **Step 2: Add a failing rollback test**

Install fixture version A. Run a second install with an invalid staged app and
assert the command returns `74` while every version-A installed artifact
remains byte-for-byte intact.

- [ ] **Step 3: Run the installer test and verify RED**

```bash
zsh Tests/InstallationTests/install-app.zsh
```

- [ ] **Step 4: Implement stage, verify, swap, and rollback**

Stage inside `~/.local/lib/simlease/.install-*`. Validate required files,
executable bits, plist syntax, and app layout before activation. Move the
current managed artifacts into a same-volume backup, move staged artifacts
into place, then bootstrap/kickstart the agent. On any activation failure,
remove only the newly activated managed artifacts and restore the backup.

Keep existing explicit environment overrides and add:

```text
SIMLEASE_SOURCE_UPDATER
SIMLEASE_SKIP_LAUNCH_AGENT
```

`SIMLEASE_SKIP_LAUNCH_AGENT=1` is only for isolated tests. Always remove staging
and backup directories on success. Preserve cache files and the existing AXe
symlink target.

- [ ] **Step 5: Extend uninstall narrowly**

Remove the installed `install-release.sh` with the other SimLease-managed
artifacts. Do not remove the cache directory, simulator data, or custom AXe
binary.

- [ ] **Step 6: Run the installer tests and verify GREEN**

```bash
zsh Tests/InstallationTests/install-app.zsh
```

---

### Task 4: Implement and test the release bootstrap

**Files:**
- Create: `scripts/install-release.sh`
- Create: `Tests/InstallationTests/install-release.zsh`

- [ ] **Step 1: Add failing bootstrap tests**

Use a local fixture release and command overrides to cover:

- macOS 15 arm64 acceptance;
- non-arm64 and macOS 14 rejection with `69`;
- latest release resolution;
- current-version no-op;
- newer-version installation;
- older latest release no-op;
- checksum mismatch returning `74`;
- unsafe archive paths returning `74`;
- missing expected layout returning `74`;
- architecture verification failure returning `74`;
- code-signature or Gatekeeper failure returning `74`; and
- propagation of bundled-installer failure.

Network, signing, OS-version, and architecture checks must be injectable only
through documented `SIMLEASE_TEST_*` environment variables that the script
rejects unless `SIMLEASE_TEST_MODE=1`.

- [ ] **Step 2: Run the bootstrap test and verify RED**

```bash
zsh Tests/InstallationTests/install-release.zsh
```

- [ ] **Step 3: Implement latest stable release resolution**

Fetch:

```text
https://api.github.com/repos/jdelaire/SimLease/releases/latest
```

Use macOS `plutil` to extract `tag_name`. Accept only `vMAJOR.MINOR.PATCH`.
Construct the two asset URLs from that validated version.

- [ ] **Step 4: Implement platform and no-downgrade checks**

Require Darwin, arm64, and macOS 15 or later. When
`--current-version MAJOR.MINOR.PATCH` is present, exit successfully without a
download if the latest release is equal or older.

- [ ] **Step 5: Implement integrity checks**

Download into a private `mktemp -d` directory. Verify SHA-256, reject absolute
or parent-traversal archive paths, extract, validate the exact required layout,
check both Mach-O executables are arm64, run strict `codesign` verification,
and run Gatekeeper assessment on the app.

- [ ] **Step 6: Delegate to the bundled installer**

Invoke the extracted `install.sh` with exact source overrides pointing into the
verified archive. Copy the verified bootstrap itself into the installed
location through `SIMLEASE_SOURCE_UPDATER`.

- [ ] **Step 7: Run bootstrap tests and verify GREEN**

```bash
zsh Tests/InstallationTests/install-release.zsh
```

---

### Task 5: Build the signed release archive

**Files:**
- Create: `scripts/package-release.sh`
- Create: `Tests/InstallationTests/package-release.zsh`
- Modify: `scripts/package-app.sh`

- [ ] **Step 1: Add a failing package-layout test**

Build an ad-hoc test package and assert the archive contains exactly:

```text
SimLease.app/
bin/simlease
install.sh
install-release.sh
Resources/com.jdelaire.simlease.plist
```

Assert the output names are
`SimLease-0.1.0-arm64.zip` and
`SimLease-0.1.0-arm64.sha256`, the checksum verifies, and both binaries are
arm64.

- [ ] **Step 2: Run the package test and verify RED**

```bash
zsh Tests/InstallationTests/package-release.zsh
```

- [ ] **Step 3: Implement release packaging**

Require `SIMLEASE_VERSION` and validate it against
`Resources/SimLease-Info.plist`. Build with:

```bash
swift build -c release --arch arm64
```

Copy only the documented archive layout. Sign the CLI and nested app
executables first, then sign the app with hardened runtime and timestamp when a
Developer ID identity is supplied. Permit identity `-` only when
`SIMLEASE_TEST_MODE=1`.

Create the zip with `ditto`, create the SHA-256 file with `shasum`, and fail if
architecture or strict signature verification fails.

- [ ] **Step 4: Keep local app packaging compatible**

Have `package-app.sh` reuse only the common app-layout behavior that reduces
duplication without changing its existing local ad-hoc output contract.

- [ ] **Step 5: Run package tests and verify GREEN**

```bash
zsh Tests/InstallationTests/package-release.zsh
```

---

### Task 6: Add the tag-driven notarized release workflow

**Required skill before implementation:** `asc-notarization`

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the release workflow**

Trigger only on tags matching `v*.*.*`. Use `macos-15`, validate the tag
against the plist version, run all Swift and shell tests, import the Developer
ID `.p12` into an ephemeral keychain, and call `package-release.sh`.

Use these repository secrets:

```text
DEVELOPER_ID_APPLICATION_P12
DEVELOPER_ID_APPLICATION_P12_PASSWORD
APPLE_API_KEY_ID
APPLE_API_ISSUER_ID
APPLE_API_PRIVATE_KEY
```

- [ ] **Step 2: Notarize and staple**

Write `APPLE_API_PRIVATE_KEY` to a mode-600 temporary `.p8`, submit the zip with
`xcrun notarytool --wait`, staple the app, validate the staple, rebuild the zip
and checksum, and rerun strict signature and Gatekeeper checks.

- [ ] **Step 3: Publish the GitHub Release**

Create the release with `gh release create "$GITHUB_REF_NAME"` and upload only
the zip and checksum. Generate release notes from commits. Set
`permissions.contents: write`.

- [ ] **Step 4: Review workflow permissions and secret handling**

Ensure no secret is echoed, temporary credentials are deleted with an `always`
cleanup step, and untrusted pull-request code cannot access release secrets.

---

### Task 7: Prepare the repository for public use

**Files:**
- Create: `LICENSE`
- Modify: `README.md`
- Modify: `.gitignore`
- Modify: `Tests/SimLeaseMenuBarTests/LeasePopoverRenderingTests.swift`

- [ ] **Step 1: Add the MIT license**

Use the standard MIT text with copyright:

```text
Copyright (c) 2026 Jérôme Delaire
```

- [ ] **Step 2: Rewrite the README as durable public documentation**

Cover purpose, install, `status --json`, naming, holding a lease, automatic
shim coordination, stale-simulator cleanup review/apply, `update`, uninstall,
managed paths, system requirements, safe-cleanup protections, release
verification, development tests, and license.

Remove dated internal verification counts and workstation-specific narrative.

- [ ] **Step 3: Remove workstation-specific fixtures**

Replace workstation-specific test fixture paths with `/Users/example/...`.

- [ ] **Step 4: Ignore only generated and credential artifacts**

Ignore release output, temporary signing files, `.p12`, and `AuthKey_*.p8`.
Do not ignore source, docs, tests, or workflow files.

- [ ] **Step 5: Audit public content**

```bash
git grep -nE \
  '(/Users/jdelaire|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|ghp_|github_pat_|AKIA)'
git status --short
```

Expected: no personal absolute paths or credential material in public files.

---

### Task 8: Run complete local verification and commit

**Required skill before completion:** `superpowers:verification-before-completion`

- [ ] **Step 1: Run all automated verification**

```bash
swift test
swift build -c release --arch arm64
zsh Tests/InstallationTests/install-app.zsh
zsh Tests/InstallationTests/install-release.zsh
zsh Tests/InstallationTests/package-release.zsh
SIMLEASE_TEST_MODE=1 SIMLEASE_VERSION=0.1.0 \
  SIMLEASE_SIGN_IDENTITY=- scripts/package-release.sh
```

- [ ] **Step 2: Verify the produced artifacts**

```bash
shasum -a 256 -c dist/SimLease-0.1.0-arm64.sha256
codesign --verify --deep --strict dist/release/SimLease.app
file dist/release/bin/simlease
file dist/release/SimLease.app/Contents/MacOS/SimLease
```

- [ ] **Step 3: Review the complete diff**

Confirm every changed line belongs to SimLease, the approved waiter UI,
cleanup, installer/updater, public documentation, or release automation.

- [ ] **Step 4: Commit the public implementation**

Stage the explicit intended paths, review `git diff --cached`, then commit:

```bash
git commit -m "feat: prepare SimLease for public release"
```

---

### Task 9: Create and configure the public GitHub repository

- [ ] **Step 1: Recheck publication gates**

Confirm the worktree has no unintended files, all tests are fresh, `gh auth
status` names `jdelaire`, and no repository named `jdelaire/SimLease` exists.

- [ ] **Step 2: Create the repository and push main**

```bash
gh repo create jdelaire/SimLease \
  --public \
  --source=. \
  --remote=origin \
  --description \
  "Coordinate shared iOS Simulator access across agents and terminal sessions, with safe stale-simulator cleanup." \
  --push
```

- [ ] **Step 3: Configure repository metadata**

Disable wiki and projects, keep issues enabled, set `main` as default, and add:

```text
macos
swift
swiftui
ios-simulator
coresimulator
codex
automation
developer-tools
```

- [ ] **Step 4: Verify local and remote identity**

Compare local `HEAD`, `refs/remotes/origin/main`, and the GitHub API SHA.
Confirm visibility, description, default branch, issues, wiki/projects, topics,
and license.

---

### Task 10: Configure credentials and publish `v0.1.0`

- [ ] **Step 1: Audit existing signing credentials without exporting secrets**

```bash
security find-identity -v -p codesigning
find "$HOME" -maxdepth 4 \( -name '*.p12' -o -name 'AuthKey_*.p8' \) -print
```

Require one usable Developer ID Application identity, its exportable `.p12`,
and an App Store Connect API key ID, issuer ID, and `.p8`.

If any credential is unavailable, stop before tagging and report the exact
missing item. Keep the already-created public repository and pushed `main`.

- [ ] **Step 2: Configure the five GitHub Actions secrets**

Set the exact secret names documented in Task 6. Base64-encode the binary
`.p12`; store the `.p8` PEM text directly. Verify only secret names and update
timestamps with `gh secret list`.

- [ ] **Step 3: Tag and push the initial release**

```bash
git tag -a v0.1.0 -m "SimLease 0.1.0"
git push origin v0.1.0
```

- [ ] **Step 4: Monitor release automation**

Watch the tag workflow to completion. On failure, inspect logs without printing
secrets, fix on `main`, retag only after deleting the failed local/remote tag
and release artifacts with explicit confirmation that no valid release was
published.

- [ ] **Step 5: Verify the public release**

Confirm release assets, checksum, notarization/staple, Gatekeeper assessment,
and public install in a temporary home. Run:

```bash
simlease --version
simlease status --json
simlease update
```

Expected: version `0.1.0`, valid JSON status, and an already-current no-op.

---

### Task 11: Add SimLease to the profile repository

**Files:**
- Modify: `../jdelaire/README.md`

- [ ] **Step 1: Recheck the adjacent repository**

Confirm branch `main`, clean worktree, and remote
`https://github.com/jdelaire/jdelaire.git`.

- [ ] **Step 2: Add the project after release verification**

Under Current Playground, add:

```markdown
- 🚦 **[SimLease](https://github.com/jdelaire/SimLease)**: Coordinates shared
  iOS Simulator access across agents and terminal sessions, with safe,
  explicitly confirmed stale-simulator cleanup.
```

- [ ] **Step 3: Review, commit, and push**

```bash
git add README.md
git diff --cached
git commit -m "Add SimLease to project list"
git push origin main
```

- [ ] **Step 4: Verify profile publication**

Compare local `HEAD`, `origin/main`, and the GitHub API SHA, then confirm the
public profile README links to the released SimLease repository.
