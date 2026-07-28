# SimLease Core and CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone, tested `simlease` CLI and PATH shims that serialize CoreSimulator interactions across Codex threads and terminal sessions.

**Architecture:** A dependency-free Swift package separates lock/metadata behavior in `SimLeaseCore`, command parsing in `SimLeaseCLI`, and the executable entry point in `simlease`. One POSIX `lockf` lock is authoritative; atomic JSON files expose owner and waiter state. Installed `xcodebuild`, `xcrun`, and `axe` symlinks enter the same executable, which classifies and delegates commands without recursion.

**Tech Stack:** Swift 6.4, Swift Package Manager, Foundation, Darwin POSIX APIs, XCTest, zsh installation scripts

## Global Constraints

- SimLease is standalone and has no source or runtime dependency on AnimAtlas, ExplorerDex, or another client project.
- Use one advisory `lockf` lock under `~/Library/Caches/SimLease/` as sole ownership authority.
- Wait at most 20 minutes; report owner every 30 seconds; timeout with exit status `75`.
- Lease every `xcrun simctl` and AXe command.
- Lease `xcodebuild` for test actions or simulator destinations; pass generic and physical-device builds through.
- Preserve exact child exit status and forward `SIGINT`, `SIGTERM`, and `SIGHUP`.
- Status, installation, tests, and cleanup must not delete or invoke simulator devices or runtimes.
- Add no third-party dependencies.

---

### Task 1: Swift package and shared status contract

**Files:**
- Create: `Package.swift`
- Create: `Sources/SimLeaseCore/LeaseModels.swift`
- Create: `Sources/SimLeaseCore/LeasePaths.swift`
- Create: `Sources/SimLeaseCLI/CLI.swift`
- Create: `Sources/simlease/main.swift`
- Create: `Tests/SimLeaseCoreTests/LeaseModelsTests.swift`
- Create: `README.md`

**Interfaces:**
- Consumes: none
- Produces: `LeaseOwner`, `LeaseWaiter`, `LeaseStatus`, `LeaseStatus.State`, `LeasePaths`, and `SimLeaseCLI.run(arguments:environment:)`

- [ ] **Step 1: Write package manifest and failing model tests**

Use this package shape:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimLease",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SimLeaseCore", targets: ["SimLeaseCore"]),
        .library(name: "SimLeaseCLI", targets: ["SimLeaseCLI"]),
        .executable(name: "simlease", targets: ["simlease"]),
    ],
    targets: [
        .target(name: "SimLeaseCore"),
        .target(name: "SimLeaseCLI", dependencies: ["SimLeaseCore"]),
        .executableTarget(name: "simlease", dependencies: ["SimLeaseCLI"]),
        .testTarget(name: "SimLeaseCoreTests", dependencies: ["SimLeaseCore"]),
        .testTarget(name: "SimLeaseCLITests", dependencies: ["SimLeaseCLI", "SimLeaseCore"]),
    ]
)
```

Test exact JSON round trips and state encoding:

```swift
import XCTest
@testable import SimLeaseCore

final class LeaseModelsTests: XCTestCase {
    func testStatusRoundTripPreservesOwnerAndWaiters() throws {
        let owner = LeaseOwner(
            pid: 41,
            acquiredAt: Date(timeIntervalSince1970: 100),
            cwd: "/Projects/AnimAtlas",
            project: "AnimAtlas",
            command: ["/usr/bin/xcodebuild", "test"],
            source: .codex,
            threadID: "019faaef-c552-7933-92dc-1cf0ff89fc06",
            threadTitle: "[AnimAtlas] Onboarding"
        )
        let waiter = LeaseWaiter(
            id: "52-120",
            pid: 52,
            waitingSince: Date(timeIntervalSince1970: 120),
            cwd: "/Projects/Set",
            project: "Set",
            command: ["/usr/bin/xcrun", "simctl", "list"],
            source: .terminal,
            threadID: nil,
            threadTitle: nil
        )
        let value = LeaseStatus(state: .leased, owner: owner, waiters: [waiter], error: nil)

        let data = try JSONEncoder.simLease.encode(value)
        XCTAssertEqual(try JSONDecoder.simLease.decode(LeaseStatus.self, from: data), value)
    }

    func testPathsStayInsideConfiguredRoot() {
        let paths = LeasePaths(root: URL(fileURLWithPath: "/tmp/simlease-test"))
        XCTAssertEqual(paths.lock.path, "/tmp/simlease-test/lease.lock")
        XCTAssertEqual(paths.owner.path, "/tmp/simlease-test/owner.json")
        XCTAssertEqual(paths.waiters.path, "/tmp/simlease-test/waiters")
        XCTAssertEqual(paths.threadNames.path, "/tmp/simlease-test/thread-names.json")
    }
}
```

- [ ] **Step 2: Run tests and verify expected failure**

Run:

```bash
swift test --filter LeaseModelsTests
```

Expected: compile failure because `LeaseOwner`, `LeaseStatus`, and `LeasePaths`
do not exist.

- [ ] **Step 3: Implement immutable Codable models and paths**

Define these exact public types:

```swift
public enum LeaseSource: String, Codable, Sendable {
    case codex
    case terminal
    case manualXcode
}

public struct LeaseOwner: Codable, Equatable, Sendable {
    public let pid: Int32
    public let acquiredAt: Date
    public let cwd: String
    public let project: String
    public let command: [String]
    public let source: LeaseSource
    public let threadID: String?
    public let threadTitle: String?
}

public struct LeaseWaiter: Codable, Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let waitingSince: Date
    public let cwd: String
    public let project: String
    public let command: [String]
    public let source: LeaseSource
    public let threadID: String?
    public let threadTitle: String?
}

public struct LeaseStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case free
        case leased
        case metadataError
    }

    public let state: State
    public let owner: LeaseOwner?
    public let waiters: [LeaseWaiter]
    public let error: String?
}
```

Add designated initializers for every model. Configure JSON dates as ISO 8601:

```swift
public extension JSONEncoder {
    static var simLease: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var simLease: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

`LeasePaths.default` resolves
`FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]`
and appends `SimLease`. Tests always pass an explicit temporary root.

Create a minimal CLI entry point:

```swift
import SimLeaseCLI
import Darwin

exit(SimLeaseCLI.run(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment
))
```

`SimLeaseCLI.run` initially prints usage to standard error and returns `64`.

- [ ] **Step 4: Run full tests and build executable**

Run:

```bash
swift test
swift build --product simlease
.build/debug/simlease
```

Expected: tests pass; executable prints usage and exits `64`.

- [ ] **Step 5: Write README boundary**

Document:

- standalone macOS menu-bar product with bundled CLI
- this first plan delivers CLI/shims only
- protected command list
- manual Xcode usage
- no force-release or simulator deletion

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests README.md
git commit -m "feat: scaffold SimLease core"
```

---

### Task 2: Protected-command classification and executable resolution

**Files:**
- Create: `Sources/SimLeaseCore/ProtectedCommand.swift`
- Create: `Sources/SimLeaseCore/ExecutableResolver.swift`
- Create: `Tests/SimLeaseCoreTests/ProtectedCommandTests.swift`
- Create: `Tests/SimLeaseCoreTests/ExecutableResolverTests.swift`

**Interfaces:**
- Consumes: process arguments and `PATH`
- Produces: `ProtectedCommand.classify(invocation:) -> ProtectionDecision` and `ExecutableResolver.resolve(name:path:excluding:) throws -> URL`

- [ ] **Step 1: Write table-driven failing classifier tests**

Cover these exact cases:

```swift
let cases: [([String], Bool)] = [
    (["xcodebuild", "test"], true),
    (["xcodebuild", "test-without-building"], true),
    (["xcodebuild", "build-for-testing"], true),
    (["xcodebuild", "-destination", "platform=iOS Simulator,name=iPhone 17", "build"], true),
    (["xcodebuild", "-destination=platform=macOS", "build"], false),
    (["xcodebuild", "-destination", "generic/platform=iOS", "build"], false),
    (["xcrun", "simctl", "list"], true),
    (["xcrun", "--sdk", "iphonesimulator", "simctl", "boot", "ABC"], true),
    (["xcrun", "swift", "--version"], false),
    (["axe", "tap", "--id", "Done"], true),
]

for (arguments, expected) in cases {
    XCTAssertEqual(ProtectedCommand.classify(invocation: arguments).requiresLease, expected)
}
```

Add resolver tests with two temporary executable directories. Ensure the shim
directory is skipped and the next executable is returned.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
swift test --filter ProtectedCommandTests
swift test --filter ExecutableResolverTests
```

Expected: compile failure because classifier and resolver do not exist.

- [ ] **Step 3: Implement classifier**

Define:

```swift
public struct ProtectionDecision: Equatable, Sendable {
    public let requiresLease: Bool
    public let toolName: String
}

public enum ProtectedCommand {
    public static func classify(invocation: [String]) -> ProtectionDecision
}
```

Classification rules:

1. Normalize tool name from `URL(fileURLWithPath: invocation[0]).lastPathComponent`.
2. For `axe`, return protected.
3. For `xcrun`, scan past global options and option values until selected tool;
   protect only when selected tool is `simctl`.
4. For `xcodebuild`, protect named test actions.
5. Also protect `xcodebuild` when `-destination` or `-destination=...` contains
   `Simulator` case-insensitively.
6. Return pass-through for other tools and inputs.

- [ ] **Step 4: Implement resolver without PATH recursion**

Define:

```swift
public enum ExecutableResolutionError: Error, Equatable {
    case notFound(String)
}

public enum ExecutableResolver {
    public static func resolve(
        name: String,
        path: String,
        excluding directory: URL
    ) throws -> URL
}
```

Split `PATH` on `:`, standardize each directory, skip the directory containing
the running shim, and return the first executable regular file with the target
name. Do not hard-code AXe's Homebrew location.

- [ ] **Step 5: Run focused and full tests**

```bash
swift test --filter ProtectedCommandTests
swift test --filter ExecutableResolverTests
swift test
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimLeaseCore Tests/SimLeaseCoreTests
git commit -m "feat: classify protected simulator commands"
```

---

### Task 3: Thread identity and atomic metadata storage

**Files:**
- Create: `Sources/SimLeaseCore/LeaseIdentity.swift`
- Create: `Sources/SimLeaseCore/MetadataStore.swift`
- Create: `Tests/SimLeaseCoreTests/LeaseIdentityTests.swift`
- Create: `Tests/SimLeaseCoreTests/MetadataStoreTests.swift`

**Interfaces:**
- Consumes: `CODEX_THREAD_ID`, optional registered title, cwd, arguments
- Produces: `LeaseIdentity.resolve(...)`, `MetadataStore.registerThreadName`, owner/waiter atomic read/write/remove methods

- [ ] **Step 1: Write failing identity and store tests**

Required identity cases:

```swift
func testRegisteredTitleWinsForCodexThread() throws {
    let store = try MetadataStore(paths: temporaryPaths())
    try store.registerThreadName(id: "019faaef", title: "[SimLease] Build CLI")

    let identity = try LeaseIdentity.resolve(
        environment: ["CODEX_THREAD_ID": "019faaef"],
        cwd: "/Users/me/Projects/SimLease",
        command: ["xcrun", "simctl", "list"],
        store: store
    )

    XCTAssertEqual(identity.source, .codex)
    XCTAssertEqual(identity.project, "SimLease")
    XCTAssertEqual(identity.threadTitle, "[SimLease] Build CLI")
}

func testMissingTitleKeepsFullIDInMetadata() throws {
    let identity = try LeaseIdentity.resolve(
        environment: ["CODEX_THREAD_ID": "019faaef-c552-7933"],
        cwd: "/Users/me/Projects/SimLease",
        command: ["axe", "tap"],
        store: try MetadataStore(paths: temporaryPaths())
    )
    XCTAssertEqual(identity.threadID, "019faaef-c552-7933")
    XCTAssertNil(identity.threadTitle)
}
```

Store tests must verify:

- owner JSON round trip
- waiters sorted by `waitingSince`
- removing one waiter preserves others
- invalid owner JSON returns a typed corruption error
- thread name rejects empty titles

- [ ] **Step 2: Run tests and verify failure**

```bash
swift test --filter LeaseIdentityTests
swift test --filter MetadataStoreTests
```

Expected: compile failure because identity/store types do not exist.

- [ ] **Step 3: Implement identity**

Define:

```swift
public struct LeaseIdentity: Equatable, Sendable {
    public let pid: Int32
    public let cwd: String
    public let project: String
    public let command: [String]
    public let source: LeaseSource
    public let threadID: String?
    public let threadTitle: String?

    public static func resolve(
        environment: [String: String],
        cwd: String,
        command: [String],
        store: MetadataStore,
        pid: Int32 = getpid()
    ) throws -> LeaseIdentity
}
```

Project is the final non-empty cwd component. A present
`CODEX_THREAD_ID` selects `.codex`; otherwise source is `.terminal`.
Registered names are optional and never block identity creation.

- [ ] **Step 4: Implement atomic metadata store**

Define:

```swift
public final class MetadataStore: @unchecked Sendable {
    public init(paths: LeasePaths) throws
    public func writeOwner(_ owner: LeaseOwner) throws
    public func readOwner() throws -> LeaseOwner?
    public func removeOwner() throws
    public func writeWaiter(_ waiter: LeaseWaiter) throws
    public func readWaiters() throws -> [LeaseWaiter]
    public func removeWaiter(id: String) throws
    public func registerThreadName(id: String, title: String) throws
    public func threadName(id: String) throws -> String?
}
```

Create root and waiter directories with user-only permissions. Every write uses
a sibling temporary file, `fsync`, then `rename`. Waiter filenames are restricted
to ASCII letters, digits, and `-`. Treat malformed JSON as
`MetadataStoreError.corruptFile(URL)`.

- [ ] **Step 5: Run all tests**

```bash
swift test --filter LeaseIdentityTests
swift test --filter MetadataStoreTests
swift test
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimLeaseCore Tests/SimLeaseCoreTests
git commit -m "feat: record simulator lease identities"
```

---

### Task 4: POSIX lease coordinator and status probe

**Files:**
- Create: `Sources/SimLeaseCore/LeaseCoordinator.swift`
- Create: `Sources/SimLeaseCore/Clock.swift`
- Create: `Tests/SimLeaseCoreTests/LeaseCoordinatorTests.swift`

**Interfaces:**
- Consumes: `LeasePaths`, `MetadataStore`, `LeaseIdentity`, timing policy
- Produces: `LeaseCoordinator.acquire`, `LeaseHandle.release`, and `LeaseCoordinator.status`

- [ ] **Step 1: Write failing cross-process tests**

Use `/usr/bin/lockf <path> /bin/sleep 5` as the independent holder process.
This exercises the same advisory-lock namespace without importing production
code into the fixture. Test:

```swift
func testSecondProcessCannotAcquireWhileFirstHoldsLock() throws {
    let fixture = try ProcessLeaseFixture()
    defer { fixture.stopHolder() }

    try fixture.startHolder()
    let result = try fixture.tryAcquire(timeout: 0.15)

    XCTAssertEqual(result, .timedOut)
}

func testLockBecomesAvailableAfterHolderExits() throws {
    let fixture = try ProcessLeaseFixture()
    try fixture.startHolder()
    fixture.stopHolder()

    let handle = try fixture.acquire(timeout: 1)
    handle.release()
}
```

Add tests for waiter cleanup, timeout `75` mapping, wait-report callbacks,
free/leased status, and corrupt/missing owner metadata while the lock is held.
Use 20–100 ms injected intervals; never sleep for production durations.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
swift test --filter LeaseCoordinatorTests
```

Expected: compile failure because coordinator types do not exist.

- [ ] **Step 3: Implement timing policy and nonblocking `lockf` loop**

Define:

```swift
public protocol LeaseClock: Sendable {
    func wallNow() -> Date
    func monotonicNow() -> ContinuousClock.Instant
    func sleep(for duration: Duration) throws
}

public struct LeaseTiming: Sendable {
    public let timeout: Duration
    public let reportInterval: Duration
    public let pollInterval: Duration

    public static let production = LeaseTiming(
        timeout: .seconds(1_200),
        reportInterval: .seconds(30),
        pollInterval: .milliseconds(200)
    )
}

public enum LeaseAcquisitionError: Error, Equatable {
    case timedOut
    case cancelled(Int32)
    case systemCall(String, Int32)
}

public final class LeaseHandle: @unchecked Sendable {
    public let owner: LeaseOwner
    public func release()
}

public final class LeaseCoordinator: @unchecked Sendable {
    public init(
        paths: LeasePaths,
        store: MetadataStore,
        timing: LeaseTiming = .production,
        clock: any LeaseClock = SystemLeaseClock()
    )

    public func acquire(
        identity: LeaseIdentity,
        onWaitReport: @escaping @Sendable (LeaseStatus) -> Void = { _ in },
        cancellationSignal: @escaping @Sendable () -> Int32? = { nil }
    ) throws -> LeaseHandle

    public func status() throws -> LeaseStatus
}
```

Open `lease.lock` with `O_CREAT | O_RDWR` and mode `0600`. Poll
`lockf(fd, F_TLOCK, 0)` until success, timeout, or cancellation. Only
`EACCES` and `EAGAIN` mean busy; other errno values fail closed.

Before polling, atomically write one waiter record. After acquisition, remove
the waiter and write owner metadata while the file descriptor remains locked.

- [ ] **Step 4: Implement handle cleanup and status**

`LeaseHandle` owns the file descriptor. Its idempotent `release()` removes owner
metadata, calls `lockf(fd, F_ULOCK, 0)`, and closes the descriptor.

`status()` opens the same file and attempts `F_TLOCK`:

- success + no owner metadata: `.free`
- success + owner metadata: `.metadataError`
- busy + valid owner metadata: `.leased`
- busy + missing/corrupt metadata: `.metadataError`

Keep a successfully probed lock until metadata is read, then unlock. Sort
waiters by `waitingSince`. Never call CoreSimulator.

- [ ] **Step 5: Run stress loop and full tests**

```bash
swift test --filter LeaseCoordinatorTests
for run_index in {1..25}; do
  swift test --filter LeaseCoordinatorTests/testSecondProcessCannotAcquireWhileFirstHoldsLock || exit 1
done
swift test
```

Expected: all pass; no leaked waiter files remain in temporary roots.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimLeaseCore Tests/SimLeaseCoreTests
git commit -m "feat: serialize simulator access with lockf"
```

---

### Task 5: Child process execution, signal forwarding, and CLI commands

**Files:**
- Create: `Sources/SimLeaseCore/ChildProcessRunner.swift`
- Create: `Sources/SimLeaseCLI/CommandParser.swift`
- Modify: `Sources/SimLeaseCLI/CLI.swift`
- Create: `Tests/SimLeaseCoreTests/ChildProcessRunnerTests.swift`
- Create: `Tests/SimLeaseCLITests/CommandParserTests.swift`
- Create: `Tests/SimLeaseCLITests/CLITests.swift`

**Interfaces:**
- Consumes: classifier, resolver, identity, coordinator
- Produces: `simlease status --json`, `simlease name`, `simlease hold`, and argv-zero shim dispatch

- [ ] **Step 1: Write failing parser and execution tests**

Parser expectations:

```swift
XCTAssertEqual(
    try CommandParser.parse(["simlease", "status", "--json"]),
    .status(json: true)
)
XCTAssertEqual(
    try CommandParser.parse(["simlease", "name", "[SimLease] CLI"]),
    .name("[SimLease] CLI")
)
XCTAssertEqual(
    try CommandParser.parse(["simlease", "hold", "--title", "Manual Xcode", "--project", "Set"]),
    .hold(title: "Manual Xcode", project: "Set")
)
XCTAssertEqual(
    try CommandParser.parse(["xcrun", "simctl", "list"]),
    .shim(arguments: ["xcrun", "simctl", "list"])
)
```

Execution tests use temporary shell fixtures that exit `0`, `7`, and by
`SIGTERM`. Verify exact status mapping, `SIMLEASE_HELD=1`, and no recursive
lease attempt when that environment value already equals `1`.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
swift test --filter CommandParserTests
swift test --filter ChildProcessRunnerTests
swift test --filter CLITests
```

Expected: compile failure because parser/runner do not exist.

- [ ] **Step 3: Implement child process runner**

Define:

```swift
public struct ChildResult: Equatable, Sendable {
    public let exitCode: Int32
}

public enum ChildProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> ChildResult
}
```

Use `posix_spawn`, preserve stdin/stdout/stderr, then `waitpid`. Install
temporary handlers for `SIGINT`, `SIGTERM`, and `SIGHUP` that forward the same
signal to the child PID. Map normal exit to `WEXITSTATUS`; map signal death to
`128 + WTERMSIG`. Restore handlers after wait.

Test signal-result mapping with a child that sends `SIGTERM` to itself. Test
parent-to-child forwarding by spawning the built `simlease` executable as an
integration subprocess, sending `SIGTERM` to that parent PID, and asserting its
sleeping child exits and the lease becomes free.

- [ ] **Step 4: Implement CLI parser and dispatch**

Define:

```swift
enum ParsedCommand: Equatable {
    case status(json: Bool)
    case name(String)
    case hold(title: String, project: String)
    case shim(arguments: [String])
}

public struct CLIConfiguration: Sendable {
    public let paths: LeasePaths
    public let timing: LeaseTiming
    public let standardOutput: @Sendable (String) -> Void
    public let standardError: @Sendable (String) -> Void

    public static let production: CLIConfiguration
}

public enum SimLeaseCLI {
    public static func run(
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration = .production
    ) -> Int32
}
```

Behavior:

- `status --json`: encode one `LeaseStatus` to stdout; return `0`, including
  `.metadataError`.
- `name TITLE`: require `CODEX_THREAD_ID`, store mapping, return `0`; missing ID
  returns `64`.
- `hold`: acquire with `.manualXcode`, print acquisition, wait until
  `SIGINT`/`SIGTERM`, then release.
- shim pass-through: resolve underlying executable and execute directly.
- shim protected: skip acquisition when `SIMLEASE_HELD=1`; otherwise acquire,
  run child with marker set, release, and return child status.
- timeout returns `75`; setup/metadata errors return `74`; usage errors return
  `64`; missing executable returns `127`.

The wait reporter writes:

```text
SimLease: waiting 00:30; owner [SimLease] CLI (SimLease), held 06:42
```

When title is missing, replace it with first eight thread-ID characters.

- [ ] **Step 5: Run focused, full, and manual fixture tests**

```bash
swift test --filter CommandParserTests
swift test --filter ChildProcessRunnerTests
swift test --filter CLITests
swift test
swift run simlease status --json | plutil -lint -
```

Expected: all tests pass; status emits valid JSON and does not start
CoreSimulator.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "feat: add SimLease command interface"
```

---

### Task 6: User installation, PATH shims, and real read-only smoke test

**Files:**
- Create: `scripts/install.sh`
- Create: `scripts/uninstall.sh`
- Create: `Tests/InstallationTests/install-cli.zsh`
- Modify: `README.md`

**Interfaces:**
- Consumes: release `simlease` binary
- Produces: `~/.local/lib/simlease/simlease`, shims in `~/.local/bin`, marked `.zprofile` PATH block

- [ ] **Step 1: Write failing installation fixture**

The shell test creates `SIMLEASE_TEST_ROOT="$(mktemp -d)"` and invokes:

```bash
SIMLEASE_INSTALL_HOME="$SIMLEASE_TEST_ROOT/home" \
SIMLEASE_SOURCE_BINARY="$PWD/.build/release/simlease" \
scripts/install.sh
```

Assert:

- executable exists at
  `$SIMLEASE_TEST_ROOT/home/.local/lib/simlease/simlease`
- `simlease`, `xcodebuild`, `xcrun`, and `axe` in `.local/bin` are symlinks to
  that executable
- `.zprofile` contains exactly one marked SimLease PATH block after two installs
- uninstall removes only those symlinks, binary, and marked block
- a pre-existing unrelated `.zprofile` line remains byte-for-byte

Use the repository's own zsh assertion functions; add no shell-test framework.

- [ ] **Step 2: Run fixture and verify failure**

```bash
swift build -c release --product simlease
zsh Tests/InstallationTests/install-cli.zsh
```

Expected: failure because install scripts do not exist.

- [ ] **Step 3: Implement idempotent installer**

Use:

```sh
SIMLEASE_USER_HOME="${SIMLEASE_INSTALL_HOME:-${HOME:?}}"
SIMLEASE_LIB_DIR="$SIMLEASE_USER_HOME/.local/lib/simlease"
SIMLEASE_BIN_DIR="$SIMLEASE_USER_HOME/.local/bin"
SIMLEASE_PROFILE="$SIMLEASE_USER_HOME/.zprofile"
```

Copy the release executable with mode `0755`. Create four symlinks using
explicit paths. Insert exactly this marked profile block:

```text
# >>> SimLease PATH >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< SimLease PATH <<<
```

Reject an install when an existing target is not a symlink owned by SimLease.
Do not overwrite unrelated executables.

- [ ] **Step 4: Implement surgical uninstaller**

Remove only symlinks whose resolved target equals the installed SimLease
binary, remove that binary, remove an empty SimLease lib directory, and remove
the exact marked profile block. Preserve cache metadata and all simulator data.

- [ ] **Step 5: Run deterministic checks**

```bash
zsh Tests/InstallationTests/install-cli.zsh
swift test
git diff --check
```

Expected: all pass.

- [ ] **Step 6: Install locally and restart shell resolution**

```bash
scripts/install.sh
exec zsh -l
```

Verify:

```bash
command -v simlease
command -v xcodebuild
command -v xcrun
command -v axe
simlease status --json
```

Expected: all four commands resolve under `~/.local/bin`; status is valid JSON.
Codex desktop must be restarted later before existing threads inherit the PATH.

- [ ] **Step 7: Run one real read-only contention smoke**

Terminal A:

```bash
simlease hold --title "Manual smoke" --project "SimLease"
```

Terminal B:

```bash
xcrun simctl list
```

Verify Terminal B waits and appears in `simlease status --json`. Release
Terminal A with `Ctrl-C`; verify Terminal B completes with native status `0`.
Do not boot, erase, delete, or shut down any device.

- [ ] **Step 8: Update README with install and operating rules**

Include:

- installation and restart requirement
- protected-command rules
- `simlease name`, `status --json`, and `hold`
- manual Xcode procedure
- timeout/exit codes
- uninstall behavior
- note that waiter display order is not strict FIFO

- [ ] **Step 9: Commit**

```bash
git add scripts Tests/InstallationTests README.md
git commit -m "feat: install SimLease command shims"
```

---

## Core plan completion gate

Run once:

```bash
swift test
zsh Tests/InstallationTests/install-cli.zsh
simlease status --json
```

Then repeat the read-only hold/`simctl list` smoke. Record:

- test counts and status
- installed command paths
- owner/waiter JSON proof
- native `simctl list` exit status
- commit SHA

Do not claim automatic protection for already-running Codex processes until
Codex desktop has restarted and a fresh thread resolves the shims.
