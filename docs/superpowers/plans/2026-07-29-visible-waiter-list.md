# Visible Waiter List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show every waiting simulator thread directly in the menu popover and
let the popover grow and shrink with its content.

**Architecture:** Keep the existing lease state and waiter metadata unchanged.
Replace only the constrained internal waiter scroller with a normal vertical
stack. The existing content-sized menu scene remains responsible for resizing
the popover.

**Tech Stack:** Swift 6, SwiftUI, Swift Package Manager, macOS 15

## Constraints

- Keep `Waiting · N` visible.
- Show every waiter name in queue order.
- Use one line per waiter, middle truncation, and the full name as help text.
- Do not add an internal scroll view or a waiter-list height cap.
- Keep the zero-waiter leased state compact.
- Preserve polling, lease behavior, cleanup behavior, and all unrelated UI.

---

### Task 1: Prove the waiter list contributes to popover height

**Files:**
- Modify: `Tests/SimLeaseMenuBarTests/LeasePopoverRenderingTests.swift`

- [ ] **Step 1: Add a failing height regression test**

Add a helper that renders `LeasePopoverView` with `ImageRenderer` and returns
the rendered image height. Build two otherwise-identical leased states: one
with no waiters and one with three named waiters. Assert that the latter is at
least 48 points taller.

```swift
func testWaiterRowsIncreasePopoverHeight() throws {
    let emptyHeight = try renderedHeight(waiters: [])
    let populatedHeight = try renderedHeight(waiters: [
        waiter(title: "Set UI tests", position: 1),
        waiter(title: "ThaiQuest screenshots", position: 2),
        waiter(title: "ExplorerDex verification", position: 3),
    ])

    XCTAssertGreaterThanOrEqual(populatedHeight - emptyHeight, 48)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
swift test --filter LeasePopoverRenderingTests/testWaiterRowsIncreasePopoverHeight
```

Expected: failure because the constrained `ScrollView` does not contribute the
full intrinsic height of all waiter rows.

---

### Task 2: Render every waiter directly

**Files:**
- Modify: `Sources/SimLeaseMenuBar/LeasePopoverView.swift`

- [ ] **Step 1: Replace the waiter scroller**

Replace the waiter `ScrollView` and `LazyVStack` with a normal `VStack`:

```swift
if !state.waiters.isEmpty {
    VStack(alignment: .leading, spacing: 5) {
        ForEach(state.waiters) { waiter in
            Text(waiter.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(waiter.title)
        }
    }
    .accessibilityLabel("Waiting tasks")
}
```

Do not apply a fixed or maximum height.

- [ ] **Step 2: Run the focused tests and verify GREEN**

```bash
swift test --filter LeasePopoverRenderingTests
swift test --filter LeasePopoverPresentationTests
```

Expected: all focused menu tests pass.

- [ ] **Step 3: Run full automated verification**

```bash
swift test
swift build -c release
scripts/package-app.sh
```

Expected: all tests pass, release build succeeds, and the app package is
created.

- [ ] **Step 4: Install and verify live resizing**

```bash
scripts/install.sh
```

Open the menu while free, then while a lease has multiple waiters, then after
the lease becomes free. Verify every waiter is visible and the popover returns
to compact height.

- [ ] **Step 5: Commit only the waiter-list change**

```bash
git add \
  Sources/SimLeaseMenuBar/LeasePopoverView.swift \
  Tests/SimLeaseMenuBarTests/LeasePopoverRenderingTests.swift \
  docs/superpowers/plans/2026-07-29-visible-waiter-list.md
git commit -m "fix: show every waiting simulator thread"
```
