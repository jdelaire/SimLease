# Enriched Waiter Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ambiguous waiter-name strings with stable, two-line waiter details in the menu-bar popover.

**Architecture:** `MenuDisplayState` maps each `LeaseWaiter` into a value-type `WaiterDisplayItem`. SwiftUI renders the item directly, while `MenuViewModel` uses the same fields for Copy Details.

**Tech Stack:** Swift 6, SwiftUI, XCTest, macOS 15.

## Global Constraints

- Primary row text is task title or the existing fallback name.
- Secondary row text is `Project · Source · Waiting duration`.
- Full command, thread ID, and working directory remain available through help, accessibility, and Copy Details.
- Stable waiter IDs identify rows.
- Existing `simlease status --json` remains unchanged.

---

### Task 1: Structured waiter display state

**Files:**
- Modify: `Sources/SimLeaseMenuCore/MenuDisplayState.swift`
- Modify: `Sources/SimLeaseMenuCore/MenuViewModel.swift`
- Test: `Tests/SimLeaseMenuBarTests/MenuDisplayStateTests.swift`
- Test: `Tests/SimLeaseMenuBarTests/MenuViewModelTests.swift`

**Interfaces:**
- Produces: `WaiterDisplayItem` with `id`, `name`, `projectAndSource`, `elapsed`, `command`, `threadID`, and `cwd`.
- Produces: `MenuDisplayState.waiters: [WaiterDisplayItem]`.

- [ ] **Step 1: Write failing state tests**

```swift
XCTAssertEqual(state.waiters[0].name, "[Set] Release validation")
XCTAssertEqual(state.waiters[0].projectAndSource, "set · Codex")
XCTAssertEqual(state.waiters[0].elapsed, "05:00")
XCTAssertEqual(state.waiters[0].id, "WAITER-1")
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `swift test --filter MenuDisplayStateTests`

Expected: compilation fails because `waiters` and `WaiterDisplayItem` do not exist.

- [ ] **Step 3: Implement structured mapping**

```swift
public struct WaiterDisplayItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let projectAndSource: String
    public let elapsed: String
    public let command: String
    public let threadID: String?
    public let cwd: String
}
```

Map `status.waiters` using the same `name`, `sourceName`, and `elapsed` helpers
used for the owner.

- [ ] **Step 4: Update Copy Details tests and implementation**

Expected waiter block:

```text
Waiting: 1
- [Set] Release validation
  set · Codex · 05:00
  xcrun simctl list devices
  Thread: 019fac4e…
  Path: /Users/example/Projects/set
```

- [ ] **Step 5: Run focused tests**

Run: `swift test --filter 'MenuDisplayStateTests|MenuViewModelTests'`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimLeaseMenuCore/MenuDisplayState.swift Sources/SimLeaseMenuCore/MenuViewModel.swift Tests/SimLeaseMenuBarTests/MenuDisplayStateTests.swift Tests/SimLeaseMenuBarTests/MenuViewModelTests.swift
git commit -m "feat: expose structured simulator waiters"
```

### Task 2: Two-line popover rows

**Files:**
- Modify: `Sources/SimLeaseMenuBar/LeasePopoverView.swift`
- Modify: `Tests/SimLeaseMenuBarTests/LeasePopoverRenderingTests.swift`

**Interfaces:**
- Consumes: `MenuDisplayState.waiters: [WaiterDisplayItem]`.
- Produces: stable, accessible two-line waiter rows.

- [ ] **Step 1: Write failing rendering assertions**

Add a rendering fixture containing duplicate task titles with distinct waiter IDs
and verify the popover height remains bounded for 20 two-line rows.

- [ ] **Step 2: Run focused test and verify failure**

Run: `swift test --filter LeasePopoverRenderingTests`

Expected: compilation or assertion failure against the old one-line rows.

- [ ] **Step 3: Render approved compact layout**

```swift
ForEach(viewModel.state.waiters) { waiter in
    VStack(alignment: .leading, spacing: 2) {
        Text(waiter.name).font(.body)
        Text("\(waiter.projectAndSource) · \(waiter.elapsed)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

Use the full command, thread ID, and path in `.help` and accessibility content.

- [ ] **Step 4: Run menu-bar tests**

Run: `swift test --filter SimLeaseMenuBarTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimLeaseMenuBar/LeasePopoverView.swift Tests/SimLeaseMenuBarTests/LeasePopoverRenderingTests.swift
git commit -m "feat: show detailed simulator waiters"
```
