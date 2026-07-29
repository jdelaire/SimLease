# Xcode Storage Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add tiered Xcode storage inventory and selective cleanup while preserving active builds, simulator leases, and guarded artifacts.

**Architecture:** Category scanners produce common fingerprinted cleanup targets. `CleanupPlanner` applies thresholds and protection rules, `CleanupPlanStore` preserves an immutable review, and `CleanupExecutor` revalidates exact selected IDs before routing rebuildable targets to permanent deletion and guarded targets to Trash.

**Tech Stack:** Swift 6, Foundation, SwiftUI, XCTest, macOS 15, existing SimLease CLI and lease coordinator.

## Global Constraints

- Temporary/custom DerivedData: 24 hours.
- Xcode previews: 7 days.
- DerivedData and project `.build`: 14 days.
- `.xcresult`: 30 days.
- Archives: 90 days.
- Device Support has no automatic stale classification.
- Guarded targets are never preselected and move to Trash.
- Booted simulators, leased simulator state, active paths, changed fingerprints, and out-of-root paths are protected.
- SimLease never force-releases, stops tests, empties Trash, deletes worktrees, or uses broad simulator deletion commands.
- Cleanup apply requires a plan ID and explicit target IDs.

---

### Task 1: General cleanup target model

**Files:**
- Modify: `Sources/SimLeaseCore/CleanupModels.swift`
- Test: `Tests/SimLeaseCoreTests/CleanupModelsTests.swift`

**Interfaces:**
- Produces: `CleanupCategory`, `CleanupRiskTier`, `CleanupAction`, `CleanupFingerprint`.
- Produces: generalized `CleanupTarget` fields and `CleanupPlan.selectedByDefault`.
- Produces: `CleanupItemOutcome.movedToTrash`.

- [ ] **Step 1: Write failing Codable and selection tests**

```swift
let target = CleanupTarget(
    kind: .filesystem,
    identifier: "derived-data:/tmp/example",
    name: "Example",
    detail: "/tmp/example",
    category: .temporaryDerivedData,
    riskTier: .rebuildable,
    action: .deletePermanently,
    path: "/tmp/example",
    runtimeIdentifier: "",
    relevantDate: now,
    sizeBytes: 42,
    fingerprint: .filesystem(path: "/tmp/example", sizeBytes: 42, modifiedAt: now),
    selectedByDefault: true
)
```

Round-trip through `JSONEncoder.simLease` and `JSONDecoder.simLease`.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter CleanupModelsTests`

Expected: missing type/member failures.

- [ ] **Step 3: Implement additive generalized model**

Keep existing device/runtime cases source-compatible where practical. Add explicit
category, action, risk, detail, path, fingerprint, and default-selection fields.
Add `CleanupPlan.targets` as the canonical list and computed device/runtime
compatibility accessors during migration.

- [ ] **Step 4: Run model tests**

Run: `swift test --filter CleanupModelsTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimLeaseCore/CleanupModels.swift Tests/SimLeaseCoreTests/CleanupModelsTests.swift
git commit -m "feat: model tiered cleanup targets"
```

### Task 2: Bounded filesystem inventory

**Files:**
- Create: `Sources/SimLeaseCore/XcodeStorageInventory.swift`
- Create: `Sources/SimLeaseCore/CleanupFileOperator.swift`
- Test: `Tests/SimLeaseCoreTests/XcodeStorageInventoryTests.swift`
- Test: `Tests/SimLeaseCoreTests/CleanupFileOperatorTests.swift`

**Interfaces:**
- Produces: `XcodeStorageInventoryProviding.inventory(now:) throws -> XcodeStorageInventory`.
- Produces: `CleanupFileOperating.delete(_:)` and `trash(_:)`.
- Produces: candidate discovery and canonical-root validation.

- [ ] **Step 1: Write failing fixture-tree tests**

Create temporary fixtures for standard DerivedData metadata, structural temporary
DerivedData, previews, `.build`, `.xcresult`, Archives, and Device Support.
Assert category, age, allocated size, action, and default selection.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter 'XcodeStorageInventoryTests|CleanupFileOperatorTests'`

Expected: missing provider/type failures.

- [ ] **Step 3: Implement scanner**

Use these fixed standard roots:

```swift
let xcode = home.appending(path: "Library/Developer/Xcode")
let derivedData = xcode.appending(path: "DerivedData")
let previews = xcode.appending(path: "UserData/Previews")
let archives = xcode.appending(path: "Archives")
let deviceSupport = xcode.appending(path: "iOS DeviceSupport")
```

Read `WorkspacePath` and `LastAccessedDate` from DerivedData `info.plist`.
Add owner/waiter CWDs supplied by the caller. Scan `.build` and `.xcresult` only
inside canonical bounded workspace roots. Reject symlink escapes.

- [ ] **Step 4: Implement exact file actions**

`delete(_:)` calls `FileManager.removeItem(at:)` only after canonical allowlist
validation. `trash(_:)` calls `FileManager.trashItem(at:resultingItemURL:)` and
never falls back to deletion.

- [ ] **Step 5: Run focused tests**

Run: `swift test --filter 'XcodeStorageInventoryTests|CleanupFileOperatorTests'`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimLeaseCore/XcodeStorageInventory.swift Sources/SimLeaseCore/CleanupFileOperator.swift Tests/SimLeaseCoreTests/XcodeStorageInventoryTests.swift Tests/SimLeaseCoreTests/CleanupFileOperatorTests.swift
git commit -m "feat: inventory bounded Xcode storage"
```

### Task 3: Planner, saved selection, and revalidating executor

**Files:**
- Modify: `Sources/SimLeaseCore/CleanupPlanner.swift`
- Modify: `Sources/SimLeaseCore/CleanupExecutor.swift`
- Modify: `Sources/SimLeaseCore/CleanupService.swift`
- Modify: `Sources/SimLeaseCore/CleanupPlanStore.swift`
- Test: `Tests/SimLeaseCoreTests/CleanupPlannerTests.swift`
- Test: `Tests/SimLeaseCoreTests/CleanupExecutorTests.swift`
- Test: `Tests/SimLeaseCoreTests/CleanupServiceTests.swift`

**Interfaces:**
- Produces: `CleanupServicing.apply(planID:selectedTargetIDs:)`.
- Consumes: simulator and filesystem inventory providers.
- Guarantees: exact-ID apply with fingerprint and active-use revalidation.

- [ ] **Step 1: Write failing planner tests**

Verify exact threshold boundaries, simulator deferral while leased, rebuildable
defaults, guarded defaults, and per-category totals.

- [ ] **Step 2: Write failing executor tests**

Verify changed/missing/active targets skip, unselected targets remain untouched,
rebuildable targets call delete, guarded targets call Trash, and Trash failure
never calls delete.

- [ ] **Step 3: Run focused tests and verify failure**

Run: `swift test --filter 'CleanupPlannerTests|CleanupExecutorTests|CleanupServiceTests'`

Expected: signature and behavior failures.

- [ ] **Step 4: Implement planning and apply**

```swift
public protocol CleanupServicing: Sendable {
    func createPlan() throws -> CleanupReview
    func apply(planID: String, selectedTargetIDs: Set<String>) throws -> CleanupResult
}
```

Filesystem scanning does not acquire the simulator lease. Simulator inventory is
attempted only when status is free. Apply reacquires simulator lease only when a
selected target is a simulator target; filesystem targets use active-path and
fingerprint protection.

- [ ] **Step 5: Run focused tests**

Run: `swift test --filter 'CleanupPlannerTests|CleanupExecutorTests|CleanupServiceTests|CleanupPlanStoreTests'`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimLeaseCore/CleanupPlanner.swift Sources/SimLeaseCore/CleanupExecutor.swift Sources/SimLeaseCore/CleanupService.swift Sources/SimLeaseCore/CleanupPlanStore.swift Tests/SimLeaseCoreTests/CleanupPlannerTests.swift Tests/SimLeaseCoreTests/CleanupExecutorTests.swift Tests/SimLeaseCoreTests/CleanupServiceTests.swift
git commit -m "feat: apply selected cleanup targets safely"
```

### Task 4: CLI and menu-provider selection contract

**Files:**
- Modify: `Sources/SimLeaseCLI/CommandParser.swift`
- Modify: `Sources/SimLeaseCLI/CLI.swift`
- Modify: `Sources/SimLeaseCLI/CleanupFormatting.swift`
- Modify: `Sources/SimLeaseMenuCore/MenuCleanupProvider.swift`
- Test: `Tests/SimLeaseCLITests/CommandParserTests.swift`
- Test: `Tests/SimLeaseCLITests/CleanupCLITests.swift`
- Test: `Tests/SimLeaseMenuBarTests/MenuCleanupProviderTests.swift`

**Interfaces:**
- Produces: `simlease clean apply PLAN --target TARGET [--target TARGET] [--json]`.
- Produces: `MenuCleanupProviding.apply(id:selectedTargetIDs:)`.

- [ ] **Step 1: Write failing parser and provider tests**

Assert at least one `--target` is required, repeated flags preserve exact IDs,
unsafe extra arguments fail with usage, and menu provider emits one flag per
selected ID.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter 'CommandParserTests|CleanupCLITests|MenuCleanupProviderTests'`

Expected: old apply signature and parser behavior fail.

- [ ] **Step 3: Implement CLI contract and grouped formatting**

Keep `status --json` unchanged. Review output groups Simulator Storage,
Rebuildable Caches, Guarded Storage, Protected, and Deferred. Apply output groups
Deleted, Moved to Trash, Skipped, and Failed.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter 'CommandParserTests|CleanupCLITests|MenuCleanupProviderTests'`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimLeaseCLI/CommandParser.swift Sources/SimLeaseCLI/CLI.swift Sources/SimLeaseCLI/CleanupFormatting.swift Sources/SimLeaseMenuCore/MenuCleanupProvider.swift Tests/SimLeaseCLITests/CommandParserTests.swift Tests/SimLeaseCLITests/CleanupCLITests.swift Tests/SimLeaseMenuBarTests/MenuCleanupProviderTests.swift
git commit -m "feat: require explicit cleanup targets"
```

### Task 5: Tiered cleanup window

**Files:**
- Modify: `Sources/SimLeaseMenuCore/CleanupViewModel.swift`
- Modify: `Sources/SimLeaseMenuBar/CleanupReviewView.swift`
- Modify: `Sources/SimLeaseMenuCore/MenuCleanupProvider.swift`
- Test: `Tests/SimLeaseMenuBarTests/CleanupViewModelTests.swift`
- Test: `Tests/SimLeaseMenuBarTests/LeasePopoverRenderingTests.swift`

**Interfaces:**
- Produces: selected target ID state, section totals, refresh, and mixed-action confirmation.
- Consumes: generalized `CleanupReview` and `CleanupResult`.

- [ ] **Step 1: Write failing view-model tests**

Verify rebuildable defaults selected, guarded defaults unchecked, protected rows
cannot select, refresh resets selection, exact selected IDs reach provider, and
button labels reflect permanent versus Trash actions.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter CleanupViewModelTests`

Expected: missing selection state and old provider signature failures.

- [ ] **Step 3: Implement selection model**

```swift
@Published public private(set) var selectedTargetIDs: Set<String> = []

public func setSelected(_ selected: Bool, targetID: String)
public var selectedDeleteBytes: Int64
public var selectedTrashCount: Int
```

- [ ] **Step 4: Implement grouped SwiftUI review**

Render Simulator Storage, Rebuildable Caches, Guarded Storage, and Protected.
Guarded starts collapsed. Each row shows name, detail, size, date/age, reason,
and disabled protection state. Confirmation separates permanent delete and
Trash movement.

- [ ] **Step 5: Run menu tests**

Run: `swift test --filter SimLeaseMenuBarTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimLeaseMenuCore/CleanupViewModel.swift Sources/SimLeaseMenuCore/MenuCleanupProvider.swift Sources/SimLeaseMenuBar/CleanupReviewView.swift Tests/SimLeaseMenuBarTests/CleanupViewModelTests.swift Tests/SimLeaseMenuBarTests/LeasePopoverRenderingTests.swift
git commit -m "feat: add tiered Xcode cleanup review"
```

### Task 6: Full regression and safe live validation

**Files:**
- Modify: `Tests/SmokeTests/cleanup-smoke.zsh`
- Modify: `README.md`

**Interfaces:**
- Verifies: fake-only cleanup routing, public usage documentation, and complete regression.

- [ ] **Step 1: Extend smoke fixture**

Add temporary rebuildable and guarded targets. Assert only repeated `--target`
IDs are acted on, guarded targets log Trash routing, and wrong/changed targets
remain untouched.

- [ ] **Step 2: Document cleanup commands**

Document:

```bash
simlease clean plan --json
simlease clean apply PLAN_ID --target TARGET_ID --json
```

State that guarded items move to Trash and simulator testing still begins only
after `simlease status --json` reports `free`.

- [ ] **Step 3: Run full automated verification**

Run: `swift test`

Run: `zsh Tests/SmokeTests/cleanup-smoke.zsh`

Expected: all tests PASS; smoke test touches temporary fixtures only.

- [ ] **Step 4: Check simulator lane and shims**

Run:

```bash
simlease status --json
command -v xcodebuild
command -v xcrun
command -v axe
```

Expected before any live simulator check: state is `free`; all three paths are
under `~/.local/lib/simlease/shims`.

If state is `leased`, stop live simulator work and report automated evidence
only. Never force-release.

- [ ] **Step 5: Commit**

```bash
git add Tests/SmokeTests/cleanup-smoke.zsh README.md
git commit -m "docs: explain Xcode storage cleanup"
```
