# SimLease Menu-Bar Application Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone macOS menu-bar application that shows the current SimLease owner, elapsed time, and waiting Codex threads without contacting CoreSimulator.

**Architecture:** A SwiftUI `MenuBarExtra` executable launches from a packaged `SimLease.app`. A status provider invokes the bundled `simlease status --json`, decodes the shared `LeaseStatus` contract, and feeds a testable `@MainActor` view model. Packaging places the menu executable and CLI in one application bundle; the user installer adds a LaunchAgent after the core CLI plan is complete.

**Tech Stack:** Swift 6.4, Swift Package Manager, SwiftUI, AppKit, Foundation, XCTest, macOS 15+

## Global Constraints

- Complete `2026-07-29-simlease-core.md` first; this plan consumes its `LeaseStatus` JSON contract and installed CLI.
- SimLease remains a standalone macOS product with no client-project dependency.
- The menu app must never invoke `simctl`, AXe, `xcodebuild`, or any simulator device operation.
- Refresh only through `simlease status --json`.
- Show Free, Leased, and Metadata Error states.
- Show owner title or shortened thread ID, project, source, abbreviated command, elapsed time, and waiting threads ordered by wait start.
- Include only Copy Details and Refresh actions.
- Add no history, notifications, preferences, analytics, or force-release control.
- Add no third-party dependencies.

---

### Task 1: Menu status projection and provider

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SimLeaseMenuCore/MenuStatusProvider.swift`
- Create: `Sources/SimLeaseMenuCore/MenuDisplayState.swift`
- Create: `Sources/SimLeaseMenuCore/MenuViewModel.swift`
- Create: `Tests/SimLeaseMenuBarTests/MenuDisplayStateTests.swift`
- Create: `Tests/SimLeaseMenuBarTests/MenuViewModelTests.swift`

**Interfaces:**
- Consumes: `LeaseStatus` from `SimLeaseCore`, bundled CLI URL
- Produces: `MenuStatusProviding.fetch()`, `MenuDisplayState`, and `MenuViewModel.refresh()`

- [ ] **Step 1: Add menu executable and test targets**

Extend `Package.swift`:

```swift
.library(name: "SimLeaseMenuCore", targets: ["SimLeaseMenuCore"]),
.executable(name: "SimLeaseMenuBar", targets: ["SimLeaseMenuBar"]),
```

Add targets:

```swift
.target(
    name: "SimLeaseMenuCore",
    dependencies: ["SimLeaseCore"]
),
.executableTarget(
    name: "SimLeaseMenuBar",
    dependencies: ["SimLeaseMenuCore"]
),
.testTarget(
    name: "SimLeaseMenuBarTests",
    dependencies: ["SimLeaseMenuCore", "SimLeaseCore"]
),
```

- [ ] **Step 2: Write failing display-state tests**

Test exact projections:

```swift
func testLeasedStateUsesTitleAndWaiters() {
    let status = LeaseStatus(
        state: .leased,
        owner: owner(
            acquiredAt: Date(timeIntervalSince1970: 100),
            threadID: "019faaef-c552-7933",
            threadTitle: "[AnimAtlas] Onboarding"
        ),
        waiters: [waiter(title: "[Set] Release validation")],
        error: nil
    )

    let state = MenuDisplayState(
        status: status,
        now: Date(timeIntervalSince1970: 502)
    )

    XCTAssertEqual(state.menuTitle, "Simulator · 06:42")
    XCTAssertEqual(state.ownerName, "[AnimAtlas] Onboarding")
    XCTAssertEqual(state.waiterNames, ["[Set] Release validation"])
    XCTAssertEqual(state.kind, .leased)
}

func testMissingTitleUsesEightCharacterThreadID() {
    let status = LeaseStatus(
        state: .leased,
        owner: owner(threadID: "019faaef-c552-7933", threadTitle: nil),
        waiters: [],
        error: nil
    )
    XCTAssertEqual(
        MenuDisplayState(status: status, now: Date()).ownerName,
        "019faaef"
    )
}

func testFreeAndErrorLabelsAreStable() {
    XCTAssertEqual(MenuDisplayState.free.menuTitle, "Simulator · Free")
    XCTAssertEqual(
        MenuDisplayState.metadataError("owner.json is corrupt").menuTitle,
        "Simulator · Error"
    )
}
```

- [ ] **Step 3: Run tests and verify expected failure**

```bash
swift test --filter MenuDisplayStateTests
```

Expected: compile failure because menu types do not exist.

- [ ] **Step 4: Implement pure display projection**

Define:

```swift
struct MenuDisplayState: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case free
        case leased
        case metadataError
    }

    let kind: Kind
    let menuTitle: String
    let symbolName: String
    let ownerName: String?
    let projectAndSource: String?
    let command: String?
    let elapsed: String?
    let waiterNames: [String]
    let error: String?

    init(status: LeaseStatus, now: Date)
    static var free: MenuDisplayState { get }
    static func metadataError(_ message: String) -> MenuDisplayState
}
```

Formatting:

- free symbol: `checkmark.circle.fill`
- leased symbol: `hourglass.circle.fill`
- error symbol: `exclamationmark.triangle.fill`
- elapsed format: `MM:SS` below one hour, `HH:MM:SS` at one hour or more
- owner: title, else first eight thread-ID characters, else
  `<source> · <project>`
- command: join arguments with spaces and keep full value in state; view
  truncates visually
- waiters: same title/ID fallback, already ordered by core status

- [ ] **Step 5: Write failing provider/view-model tests**

Use:

```swift
protocol MenuStatusProviding: Sendable {
    func fetch() async throws -> LeaseStatus
}

actor StatusStub: MenuStatusProviding {
    let result: Result<LeaseStatus, Error>
    func fetch() async throws -> LeaseStatus { try result.get() }
}
```

Verify:

- refresh publishes leased fixture
- provider error publishes metadata-error state with exact localized
  description
- `copyDetailsText` contains owner, project, command, elapsed, and waiters
- repeated refresh replaces rather than appends waiters

- [ ] **Step 6: Implement process-backed provider and view model**

`CLIStatusProvider` resolves executable in this order:

1. `SIMLEASE_EXECUTABLE_PATH`, used only by development/tests
2. `Bundle.main.url(forResource: "simlease", withExtension: nil, subdirectory: "bin")`
3. `~/.local/lib/simlease/simlease`

Run only:

```text
simlease status --json
```

Capture stdout and stderr. Nonzero exit throws
`MenuStatusError.commandFailed(code:stderr:)`; invalid JSON throws
`MenuStatusError.invalidJSON`.

Define:

```swift
@MainActor
final class MenuViewModel: ObservableObject {
    @Published private(set) var state: MenuDisplayState

    init(provider: any MenuStatusProviding, now: @escaping () -> Date = Date.init)
    func refresh() async
    var copyDetailsText: String { get }
}
```

- [ ] **Step 7: Run focused and full tests**

```bash
swift test --filter SimLeaseMenuBarTests
swift test
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/SimLeaseMenuCore Tests/SimLeaseMenuBarTests
git commit -m "feat: project simulator status for menu bar"
```

---

### Task 2: Native menu-bar interface

**Files:**
- Create: `Sources/SimLeaseMenuBar/SimLeaseMenuBarApp.swift`
- Create: `Sources/SimLeaseMenuBar/LeasePopoverView.swift`
- Create: `Sources/SimLeaseMenuCore/StatusTheme.swift`
- Modify: `Tests/SimLeaseMenuBarTests/MenuDisplayStateTests.swift`

**Interfaces:**
- Consumes: `MenuViewModel.state` and `copyDetailsText`
- Produces: native `MenuBarExtra` and compact popover matching approved option A

- [ ] **Step 1: Add failing theme assertions**

Keep color choice testable without snapshot dependencies:

```swift
func testKindsMapToApprovedColorNames() {
    XCTAssertEqual(StatusTheme.colorName(for: .free), "green")
    XCTAssertEqual(StatusTheme.colorName(for: .leased), "orange")
    XCTAssertEqual(StatusTheme.colorName(for: .metadataError), "red")
}
```

- [ ] **Step 2: Run focused test and verify failure**

```bash
swift test --filter MenuDisplayStateTests/testKindsMapToApprovedColorNames
```

Expected: compile failure because `StatusTheme` does not exist.

- [ ] **Step 3: Implement app entry and refresh cadence**

Use:

```swift
@main
struct SimLeaseMenuBarApp: App {
    @StateObject private var viewModel = MenuViewModel(provider: CLIStatusProvider())

    var body: some Scene {
        MenuBarExtra {
            LeasePopoverView(viewModel: viewModel)
                .task { await viewModel.refresh() }
        } label: {
            Label(viewModel.state.menuTitle, systemImage: viewModel.state.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}
```

Inside `LeasePopoverView`, start a cancellable 2-second refresh loop while the
popover is visible. Stop it when view disappears. The explicit Refresh button
starts one immediate refresh.

- [ ] **Step 4: Implement compact approved popover**

Use a fixed `320` point width and native materials. Content order:

1. state header and elapsed time
2. owner title or ID
3. project and source
4. one-line monospaced truncated command
5. divider
6. `Waiting · N`
7. waiter rows in wait-start order
8. error text only for metadata error
9. Copy Details and Refresh buttons

Free state shows `Simulator available` and no empty owner/queue placeholders.
Metadata error uses red status styling and exact error text.

Use:

```swift
Button("Copy details") {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(viewModel.copyDetailsText, forType: .string)
}

Button("Refresh") {
    Task { await viewModel.refresh() }
}
```

No release, kill, clear, retry-CoreSimulator, preferences, or history control.

- [ ] **Step 5: Build and inspect all fixture states**

Add a DEBUG launch environment parser:

```text
SIMLEASE_PREVIEW_STATE=free
SIMLEASE_PREVIEW_STATE=leased
SIMLEASE_PREVIEW_STATE=error
```

The parser selects static local fixtures before creating
`CLIStatusProvider`; release builds ignore this variable.

Run:

```bash
swift build --product SimLeaseMenuBar
SIMLEASE_PREVIEW_STATE=free swift run SimLeaseMenuBar
SIMLEASE_PREVIEW_STATE=leased swift run SimLeaseMenuBar
SIMLEASE_PREVIEW_STATE=error swift run SimLeaseMenuBar
```

For each state, inspect:

- menu label and symbol
- 320-point popover hierarchy
- long title/command truncation
- waiter count and ordering
- absence of destructive controls

Quit each process before launching the next fixture.

- [ ] **Step 6: Run tests**

```bash
swift test --filter SimLeaseMenuBarTests
swift test
git diff --check
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/SimLeaseMenuBar Sources/SimLeaseMenuCore Tests/SimLeaseMenuBarTests
git commit -m "feat: show simulator owner in menu bar"
```

---

### Task 3: Application bundle and login startup

**Files:**
- Create: `Resources/SimLease-Info.plist`
- Create: `Resources/com.jdelaire.simlease.plist`
- Create: `scripts/package-app.sh`
- Modify: `scripts/install.sh`
- Modify: `scripts/uninstall.sh`
- Create: `Tests/InstallationTests/package-app.zsh`
- Create: `Tests/InstallationTests/install-app.zsh`
- Modify: `README.md`

**Interfaces:**
- Consumes: release `simlease` and `SimLeaseMenuBar` executables
- Produces: `dist/SimLease.app`, `~/Applications/SimLease.app`, login LaunchAgent

- [ ] **Step 1: Write static bundle metadata**

`Resources/SimLease-Info.plist` must contain:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>SimLeaseMenuBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.jdelaire.simlease</string>
  <key>CFBundleName</key>
  <string>SimLease</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
```

LaunchAgent template runs:

```text
~/Applications/SimLease.app/Contents/MacOS/SimLeaseMenuBar
```

with `RunAtLoad` true and `KeepAlive` false.

- [ ] **Step 2: Write failing package/install fixtures**

`package-app.zsh` asserts:

- valid `Info.plist`
- executable menu binary at `Contents/MacOS/SimLeaseMenuBar`
- CLI at `Contents/Resources/bin/simlease`
- `codesign --verify --deep --strict dist/SimLease.app` succeeds

`install-app.zsh` uses `SIMLEASE_INSTALL_HOME` and asserts:

- bundle installed at `Applications/SimLease.app`
- LaunchAgent path expands to that test home
- second install produces no duplicate PATH block or agent
- uninstall removes only SimLease bundle, agent, shims, and marked PATH block
- unrelated files in `Applications` and `Library/LaunchAgents` remain

- [ ] **Step 3: Run fixtures and verify failure**

```bash
zsh Tests/InstallationTests/package-app.zsh
zsh Tests/InstallationTests/install-app.zsh
```

Expected: failure because packaging and app installation are absent.

- [ ] **Step 4: Implement deterministic bundle packaging**

`scripts/package-app.sh`:

1. runs `swift build -c release --product simlease`
2. runs `swift build -c release --product SimLeaseMenuBar`
3. recreates only repository-local `dist/SimLease.app`
4. copies static plist
5. copies binaries into exact bundle locations with mode `0755`
6. signs ad hoc:

```bash
codesign --force --deep --sign - dist/SimLease.app
```

Never delete outside repository-local `dist/SimLease.app`.

- [ ] **Step 5: Extend installer and uninstaller**

Installer copies the bundle into `$SIMLEASE_USER_HOME/Applications/SimLease.app`
and renders the LaunchAgent with the absolute executable path. For a real user
install, run:

```bash
launchctl bootstrap "gui/$(id -u)" \
  "$SIMLEASE_USER_HOME/Library/LaunchAgents/com.jdelaire.simlease.plist"
```

If already bootstrapped, use `launchctl kickstart -k
gui/$(id -u)/com.jdelaire.simlease`. Skip `launchctl` when
`SIMLEASE_INSTALL_HOME` is set, so tests never mutate the real GUI session.

Uninstaller calls `launchctl bootout` only for the SimLease label, then removes
only the exact bundle and agent paths before performing core CLI cleanup.

- [ ] **Step 6: Run deterministic verification**

```bash
zsh Tests/InstallationTests/package-app.zsh
zsh Tests/InstallationTests/install-app.zsh
swift test
git diff --check
```

Expected: all pass.

- [ ] **Step 7: Install and verify native launch**

```bash
scripts/package-app.sh
scripts/install.sh
open "$HOME/Applications/SimLease.app"
launchctl print "gui/$(id -u)/com.jdelaire.simlease"
```

Expected: app has no Dock icon, menu-bar item appears, LaunchAgent is loaded,
and `simlease status --json` remains valid.

- [ ] **Step 8: Update README**

Add:

- packaging command
- app and CLI install paths
- login startup behavior
- menu states and actions
- local uninstall command
- explicit statement that menu app is read-only

- [ ] **Step 9: Commit**

```bash
git add Package.swift Resources scripts Tests/InstallationTests README.md
git commit -m "feat: package SimLease menu app"
```

---

### Task 4: End-to-end ownership visualization

**Files:**
- Create: `Tests/SmokeTests/menu-owner-smoke.zsh`
- Modify: `README.md`

**Interfaces:**
- Consumes: installed app, CLI, shims, LaunchAgent
- Produces: reproducible real-Mac validation record without destructive simulator actions

- [ ] **Step 1: Write smoke harness around a fake protected tool**

The harness creates temporary fake underlying tools outside the shim directory,
prepends both directories to a task-specific `SIMLEASE_SMOKE_PATH`, and:

1. starts a protected fake `xcrun simctl list` holder
2. waits for status `.leased`
3. starts a second protected fake command
4. waits for one waiter
5. verifies owner thread ID/title fallback and waiter order
6. releases holder
7. verifies both commands return `0`
8. verifies final state `.free`

The harness uses a temporary cache root through a DEBUG-only
`SIMLEASE_CACHE_ROOT` override. Release builds ignore that override unless
compiled with `-D SIMLEASE_TESTING`.

- [ ] **Step 2: Run fake end-to-end smoke**

```bash
swift build -c debug -Xswiftc -DSIMLEASE_TESTING
zsh Tests/SmokeTests/menu-owner-smoke.zsh
```

Expected: all assertions pass without invoking real CoreSimulator.

- [ ] **Step 3: Restart Codex and verify fresh-thread PATH**

Quit and reopen Codex desktop. In a newly created, correctly named and pinned
thread, run:

```bash
command -v xcodebuild
command -v xcrun
command -v axe
printf '%s\n' "$CODEX_THREAD_ID"
simlease name "[SimLease] Verification"
```

Expected: shims resolve under `~/.local/lib/simlease/shims`; thread ID is
non-empty; title registration succeeds. Excluding the shim directory resolves
the preserved custom AXe binary.

- [ ] **Step 4: Run real read-only owner/waiter proof**

Terminal A:

```bash
simlease hold --title "Manual smoke" --project "SimLease"
```

Fresh Codex thread:

```bash
xcrun simctl list
```

While waiting, verify menu popover shows:

- `Manual Xcode · SimLease` owner
- elapsed time
- fresh Codex thread title or shortened ID as waiter
- abbreviated `xcrun simctl list` command

Release Terminal A. Verify Codex command returns native status `0` and menu
returns to `Simulator · Free`.

- [ ] **Step 5: Verify error and long-content fixtures**

Launch DEBUG fixtures and visually confirm:

- metadata error uses red state and exact error
- 60-character thread title truncates without hiding project or elapsed time
- 120-character command remains single-line
- ten waiters fit through scrolling
- only Copy Details and Refresh actions exist

- [ ] **Step 6: Run final automated gate**

```bash
swift test
zsh Tests/InstallationTests/install-cli.zsh
zsh Tests/InstallationTests/package-app.zsh
zsh Tests/InstallationTests/install-app.zsh
zsh Tests/SmokeTests/menu-owner-smoke.zsh
codesign --verify --deep --strict "$HOME/Applications/SimLease.app"
```

Expected: all commands exit `0`.

- [ ] **Step 7: Record verification and commit**

Add a dated Verification section to `README.md` containing:

- Swift test count
- shell fixture results
- installed binary paths
- fresh Codex PATH proof
- read-only `simctl list` native exit status
- visual-state checks
- residual limitation: manual Xcode hold remains explicit

```bash
git add Tests/SmokeTests README.md
git commit -m "test: verify SimLease ownership surface"
```

---

## Menu-bar plan completion gate

Completion requires:

- full Swift suite green
- installation/package/smoke scripts green
- signed local app bundle
- fresh Codex thread resolving all shims
- real read-only owner/waiter proof
- visual inspection of Free, Leased, waiting, and Metadata Error states
- both SimLease and client-project worktrees clean

Report commit SHA and distinguish deterministic fixtures, real read-only
CoreSimulator proof, and manual visual inspection.
