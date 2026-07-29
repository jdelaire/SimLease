# SimLease Menu Popover Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the loose, button-heavy menu popover with the approved compact,
status-first native macOS presentation.

**Architecture:** Keep `MenuViewModel`, polling, pasteboard behavior, and cleanup
window routing unchanged. Restructure only `LeasePopoverView` into a semantic
status header, conditional lease details, a secondary cleanup row, and compact
footer actions.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Package Manager, macOS 15

## Global Constraints

- Keep the popover near 320 points wide and let its height follow content.
- Use green, orange, or red only to communicate status.
- Preserve the two-second refresh loop and all existing action behavior.
- Preserve exact lease metadata and metadata-error text.
- Do not add dependencies, cards, gradients, decorative backgrounds, or a
  second accent color.
- Touch only `LeasePopoverView`, the focused presentation test, and its package
  test-target dependency.
- Do not commit, stage, or clean unrelated workspace changes.

---

### Task 1: Compact status-first popover

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/SimLeaseMenuBar/LeasePopoverView.swift`
- Create: `Tests/SimLeaseMenuBarTests/LeasePopoverPresentationTests.swift`

**Interfaces:**
- Consumes: `MenuViewModel.state`, `MenuViewModel.copyDetailsText`,
  `MenuViewModel.refresh()`, and `openWindow(id: "cleanup")`
- Produces: the same `LeasePopoverView(viewModel:)` interface plus
  `LeasePopoverPresentation.init(state:)`, which supplies the status title and
  description used by the view.

- [x] **Step 1: Let menu-bar tests import the executable target**

```swift
.testTarget(
    name: "SimLeaseMenuBarTests",
    dependencies: [
        "SimLeaseMenuBar",
        "SimLeaseMenuCore",
        "SimLeaseCore",
    ]
),
```

- [x] **Step 2: Add the failing presentation-state tests**

```swift
import XCTest
@testable import SimLeaseCore
@testable import SimLeaseMenuBar

final class LeasePopoverPresentationTests: XCTestCase {
    func testFreeStateExplainsThatTestingCanStart() {
        let presentation = LeasePopoverPresentation(state: .free)

        XCTAssertEqual(presentation.title, "Simulator available")
        XCTAssertEqual(
            presentation.description,
            "Ready for simulator testing."
        )
    }

    func testMetadataErrorPreservesExactMessage() {
        let presentation = LeasePopoverPresentation(
            state: .metadataError("metadata exploded")
        )

        XCTAssertEqual(presentation.title, "Simulator status error")
        XCTAssertEqual(presentation.description, "metadata exploded")
    }

    func testLeasedStateUsesProjectAndSource() {
        let state = MenuDisplayState(
            status: LeaseStatus(
                state: .leased,
                owner: LeaseOwner(
                    pid: 1,
                    acquiredAt: Date(timeIntervalSince1970: 100),
                    cwd: "/tmp/SimLease",
                    project: "SimLease",
                    command: ["xcodebuild", "test"],
                    source: .codex,
                    threadID: nil,
                    threadTitle: "Owner task"
                ),
                waiters: [],
                error: nil
            ),
            now: Date(timeIntervalSince1970: 102)
        )

        let presentation = LeasePopoverPresentation(state: state)

        XCTAssertEqual(presentation.title, "Simulator in use")
        XCTAssertEqual(presentation.description, "SimLease · Codex")
    }
}
```

- [x] **Step 3: Run the focused tests and verify RED**

```bash
swift test --filter LeasePopoverPresentationTests
```

Expected: compile failure because `LeasePopoverPresentation` does not exist.

- [x] **Step 4: Add the minimal presentation mapping**

Add this file-private-to-module type in `LeasePopoverView.swift`:

```swift
struct LeasePopoverPresentation: Equatable {
    let title: String
    let description: String

    init(state: MenuDisplayState) {
        switch state.kind {
        case .free:
            title = "Simulator available"
            description = "Ready for simulator testing."
        case .leased:
            title = "Simulator in use"
            description = state.projectAndSource ?? ""
        case .metadataError:
            title = "Simulator status error"
            description = state.error ?? ""
        }
    }
}
```

- [x] **Step 5: Run the focused tests and verify GREEN**

```bash
swift test --filter LeasePopoverPresentationTests
```

Expected: all three focused tests pass.

- [x] **Step 6: Implement the compact status header**

In `LeasePopoverView.swift`, replace the current free/error labels and leased
header with a shared header that uses
`LeasePopoverPresentation(state: viewModel.state)`. It must keep elapsed time
trailing for a leased state, combine the header into one accessibility element,
and apply `.contentTransition(.symbolEffect(.replace))` to the status symbol.

The header layout is:

```swift
let presentation = LeasePopoverPresentation(state: viewModel.state)

HStack(alignment: .top, spacing: 10) {
    Image(systemName: viewModel.state.symbolName)
        .font(.title3)
        .foregroundStyle(statusColor)
        .contentTransition(.symbolEffect(.replace))

    VStack(alignment: .leading, spacing: 3) {
        Text(presentation.title)
            .font(.headline)
            .contentTransition(.opacity)
        Text(presentation.description)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textSelection(viewModel.state.kind == .metadataError ? .enabled : .disabled)
            .contentTransition(.opacity)
    }

    Spacer(minLength: 8)

    if let elapsed = viewModel.state.elapsed {
        Text(elapsed)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
.accessibilityElement(children: .combine)
```

- [x] **Step 7: Make leased metadata compact**

Keep owner, command, waiter count, and waiter names. Remove the repeated
project/source line because it is now in the status header. Preserve:

- semibold owner text with one-line truncation and help;
- monospaced, middle-truncated command with help;
- `Waiting · N`;
- the existing 180-point maximum waiter scroll height; and
- the `Waiting tasks` accessibility label.

- [x] **Step 8: Replace the action stack**

Place a divider below status/details. Render cleanup as a full-width plain
button row:

```swift
Button {
    openWindow(id: "cleanup")
} label: {
    HStack {
        Label("Review Cleanup…", systemImage: "internaldrive")
        Spacer()
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
.accessibilityHint("Opens simulator storage cleanup review")
```

Add another divider, then place `Copy Details` and `Refresh` together at the
trailing edge in one `HStack`. Keep their current closures unchanged.

- [x] **Step 9: Apply compact sizing and restrained transitions**

Use a leading `VStack` with 12-point section spacing, 16-point padding, and the
existing fixed width of 320 points. Animate only changes to
`viewModel.state.kind`:

```swift
.animation(.easeInOut(duration: 0.15), value: viewModel.state.kind)
```

Do not animate the two-second elapsed-time refresh.

- [x] **Step 10: Run focused and full automated checks**

Run:

```bash
swift test --filter LeasePopoverPresentationTests
swift test
swift build --product SimLeaseMenuBar
```

Expected: all three commands pass.

### Task 2: Package and visually verify

**Files:**
- Verify only: `dist/SimLease.app`

**Interfaces:**
- Consumes: the built `SimLeaseMenuBar` executable and existing packaging script
- Produces: a locally installed/running app for human validation

- [x] **Step 1: Package and validate the app**

Run:

```bash
zsh Tests/InstallationTests/package-app.zsh
```

Expected: `package-app: PASS`.

- [x] **Step 2: Install through the existing installation test**

Run:

```bash
zsh Tests/InstallationTests/install-app.zsh
```

Expected: `install-app: PASS` and the LaunchAgent is running the newly packaged
app.

- [ ] **Step 3: Capture runtime evidence**

Open the menu extra and capture the free-state popover. Use the existing
`SIMLEASE_PREVIEW_STATE` debug provider to capture leased and metadata-error
states without changing production behavior.

Confirm in all three states:

- the status reads first and stays left aligned;
- cleanup is visibly secondary;
- footer actions are compact;
- content is neither clipped nor truncated unexpectedly; and
- the popover height follows the visible content.

- [ ] **Step 4: Report validation boundaries**

Report automated checks, package/install result, and each captured state
separately. Do not call visual validation complete for any state that was not
actually captured.
