import Foundation

public struct XcodeStorageInventory: Equatable, Sendable {
    public let targets: [CleanupTarget]
    public let protected: [ProtectedCleanupTarget]

    public init(
        targets: [CleanupTarget],
        protected: [ProtectedCleanupTarget]
    ) {
        self.targets = targets
        self.protected = protected
    }
}

public protocol XcodeStorageInventoryProviding: Sendable {
    func inventory(now: Date) throws -> XcodeStorageInventory
}

public final class XcodeStorageInventoryProvider:
    XcodeStorageInventoryProviding,
    @unchecked Sendable
{
    private let homeDirectory: URL
    private let temporaryDirectory: URL
    private let configuredWorkspaceRoots: [URL]
    private let fixedActivePaths: [URL]
    private let activeUseProvider: (any ActiveUseProviding)?
    private let fileManager: FileManager

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        workspaceRoots: [URL] = [],
        activePaths: [String] = [],
        activeUseProvider: (any ActiveUseProviding)? = nil,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = Self.canonical(homeDirectory)
        self.temporaryDirectory = Self.canonical(temporaryDirectory)
        configuredWorkspaceRoots = workspaceRoots.map(Self.canonical)
        fixedActivePaths = activePaths.map {
            Self.canonical(URL(fileURLWithPath: $0))
        }
        self.activeUseProvider = activeUseProvider
        self.fileManager = fileManager
    }

    public func inventory(now: Date) throws -> XcodeStorageInventory {
        var targets = [CleanupTarget]()
        var protected = [ProtectedCleanupTarget]()
        let activePaths = fixedActivePaths + (
            try activeUseProvider?.activePaths() ?? []
        ).map {
            Self.canonical(URL(fileURLWithPath: $0))
        }
        let xcode = homeDirectory.appending(path: "Library/Developer/Xcode")
        let derivedData = xcode.appending(path: "DerivedData")

        scanImmediateDirectories(
            at: derivedData,
            category: .derivedData,
            threshold: 14 * 86_400,
            now: now,
            dateOverride: derivedDataLastAccessed
        ) {
            append(
                $0,
                activePaths: activePaths,
                targets: &targets,
                protected: &protected
            )
        }

        scanImmediateDirectories(
            at: xcode.appending(path: "UserData/Previews"),
            category: .previews,
            threshold: 7 * 86_400,
            now: now
        ) {
            append(
                $0,
                activePaths: activePaths,
                targets: &targets,
                protected: &protected
            )
        }

        scanImmediateDirectories(
            at: temporaryDirectory,
            category: .temporaryDerivedData,
            threshold: 24 * 60 * 60,
            now: now,
            filter: isStructuredDerivedData
        ) {
            append(
                $0,
                activePaths: activePaths,
                targets: &targets,
                protected: &protected
            )
        }

        for root in workspaceRoots(derivedData: derivedData) {
            scanWorkspace(
                root,
                now: now,
                activePaths: activePaths,
                targets: &targets,
                protected: &protected
            )
        }

        scanBundles(
            at: xcode.appending(path: "Archives"),
            suffix: ".xcarchive",
            category: .archive,
            threshold: 90 * 86_400,
            now: now
        ) {
            append(
                $0,
                activePaths: activePaths,
                targets: &targets,
                protected: &protected
            )
        }

        scanImmediateDirectories(
            at: xcode.appending(path: "iOS DeviceSupport"),
            category: .deviceSupport,
            threshold: 0,
            now: now
        ) {
            append(
                $0,
                activePaths: activePaths,
                targets: &targets,
                protected: &protected
            )
        }

        return XcodeStorageInventory(
            targets: deduplicate(targets).sorted(by: targetOrder),
            protected: protected.sorted {
                targetOrder($0.target, $1.target)
            }
        )
    }

    private func scanWorkspace(
        _ root: URL,
        now: Date,
        activePaths: [URL],
        targets: inout [CleanupTarget],
        protected: inout [ProtectedCleanupTarget]
    ) {
        scanBundles(
            at: root,
            suffix: ".xcresult",
            category: .resultBundle,
            threshold: 30 * 86_400,
            now: now
        ) {
            append(
                $0,
                activePaths: activePaths,
                targets: &targets,
                protected: &protected
            )
        }
        scanNamedDirectories(
            at: root,
            name: ".build",
            category: .swiftBuild,
            threshold: 14 * 86_400,
            now: now
        ) {
            append(
                $0,
                activePaths: activePaths,
                targets: &targets,
                protected: &protected
            )
        }
    }

    private func scanImmediateDirectories(
        at root: URL,
        category: CleanupCategory,
        threshold: TimeInterval,
        now: Date,
        dateOverride: ((URL) -> Date?)? = nil,
        filter: (URL) -> Bool = { _ in true },
        consume: (CleanupTarget) -> Void
    ) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in urls where isDirectory(url) && filter(url) {
            guard let target = makeTarget(
                url,
                category: category,
                threshold: threshold,
                now: now,
                relevantDate: dateOverride?(url)
            ) else {
                continue
            }
            consume(target)
        }
    }

    private func scanBundles(
        at root: URL,
        suffix: String,
        category: CleanupCategory,
        threshold: TimeInterval,
        now: Date,
        consume: (CleanupTarget) -> Void
    ) {
        enumerateDirectories(at: root) { url, skipDescendants in
            guard url.lastPathComponent.hasSuffix(suffix) else { return }
            skipDescendants = true
            if let target = makeTarget(
                url,
                category: category,
                threshold: threshold,
                now: now
            ) {
                consume(target)
            }
        }
    }

    private func scanNamedDirectories(
        at root: URL,
        name: String,
        category: CleanupCategory,
        threshold: TimeInterval,
        now: Date,
        consume: (CleanupTarget) -> Void
    ) {
        enumerateDirectories(at: root) { url, skipDescendants in
            guard url.lastPathComponent == name else { return }
            skipDescendants = true
            if let target = makeTarget(
                url,
                category: category,
                threshold: threshold,
                now: now
            ) {
                consume(target)
            }
        }
    }

    private func enumerateDirectories(
        at root: URL,
        visit: (URL, inout Bool) -> Void
    ) {
        guard isDirectory(root),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
              )
        else {
            return
        }
        while let url = enumerator.nextObject() as? URL {
            guard isDirectory(url) else { continue }
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            var skip = false
            visit(url, &skip)
            if skip {
                enumerator.skipDescendants()
            }
        }
    }

    private func makeTarget(
        _ rawURL: URL,
        category: CleanupCategory,
        threshold: TimeInterval,
        now: Date,
        relevantDate override: Date? = nil
    ) -> CleanupTarget? {
        let url = Self.canonical(rawURL)
        guard Self.contains(homeDirectory, url)
                || Self.contains(temporaryDirectory, url)
        else {
            return nil
        }
        let metrics = directoryMetrics(url)
        let relevantDate = override ?? metrics.modifiedAt
        guard let relevantDate,
              threshold == 0
                || now.timeIntervalSince(relevantDate) >= threshold
        else {
            return nil
        }
        let guarded = Self.isGuarded(category)
        return CleanupTarget(
            kind: .filesystem,
            identifier: "\(category.rawValue):\(url.path)",
            name: url.lastPathComponent,
            detail: url.path,
            category: category,
            riskTier: guarded ? .guarded : .rebuildable,
            action: guarded ? .moveToTrash : .deletePermanently,
            path: url.path,
            runtimeIdentifier: "",
            lastUsedAt: relevantDate,
            sizeBytes: metrics.sizeBytes,
            fingerprint: .filesystem(
                path: url.path,
                sizeBytes: metrics.sizeBytes,
                modifiedAt: relevantDate
            ),
            selectedByDefault: !guarded
        )
    }

    private func append(
        _ target: CleanupTarget,
        activePaths: [URL],
        targets: inout [CleanupTarget],
        protected: inout [ProtectedCleanupTarget]
    ) {
        if isActive(target.path, activePaths: activePaths) {
            protected.append(
                ProtectedCleanupTarget(
                    target: target,
                    reason: .activePath,
                    explanation: "A running build or test uses this path"
                )
            )
        } else {
            targets.append(target)
        }
    }

    private func workspaceRoots(derivedData: URL) -> [URL] {
        var roots = configuredWorkspaceRoots
        if let derived = try? fileManager.contentsOfDirectory(
            at: derivedData,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for directory in derived where isDirectory(directory) {
                guard let workspace = derivedDataWorkspacePath(directory) else {
                    continue
                }
                roots.append(Self.canonical(workspace))
            }
        }
        let home = homeDirectory.path + "/"
        return Array(
            Dictionary(
                roots
                    .filter { $0.path.hasPrefix(home) }
                    .map { ($0.path, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )
    }

    private func derivedDataLastAccessed(_ directory: URL) -> Date? {
        guard let data = try? Data(contentsOf: directory.appending(path: "info.plist")),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any]
        else {
            return nil
        }
        return plist["LastAccessedDate"] as? Date
    }

    private func derivedDataWorkspacePath(_ directory: URL) -> URL? {
        guard let data = try? Data(contentsOf: directory.appending(path: "info.plist")),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let path = plist["WorkspacePath"] as? String
        else {
            return nil
        }
        let workspace = URL(fileURLWithPath: path)
        return workspace.deletingLastPathComponent()
    }

    private func isStructuredDerivedData(_ directory: URL) -> Bool {
        let markers = [
            "Build",
            "Build/Intermediates.noindex",
            "Build/Products",
            "SourcePackages",
        ]
        return markers.contains {
            fileManager.fileExists(
                atPath: directory.appending(path: $0).path
            )
        }
    }

    private func isActive(
        _ path: String?,
        activePaths: [URL]
    ) -> Bool {
        guard let path else { return false }
        let target = Self.canonical(URL(fileURLWithPath: path))
        return activePaths.contains {
            Self.contains(target, $0) || Self.contains($0, target)
        }
    }

    private func directoryMetrics(_ root: URL) -> (
        sizeBytes: Int64,
        modifiedAt: Date?
    ) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
        ]
        var size = Int64(0)
        var newest: Date?
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true
                else {
                    continue
                }
                size += Int64(
                    values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? 0
                )
                if let modified = values.contentModificationDate,
                   newest == nil || modified > newest! {
                    newest = modified
                }
            }
        }
        if newest == nil {
            newest = try? root.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        }
        return (size, newest)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func deduplicate(_ targets: [CleanupTarget]) -> [CleanupTarget] {
        Array(
            Dictionary(
                targets.map { ($0.identifier, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )
    }

    private func targetOrder(_ lhs: CleanupTarget, _ rhs: CleanupTarget) -> Bool {
        if lhs.category != rhs.category {
            return lhs.category.rawValue < rhs.category.rawValue
        }
        return lhs.identifier < rhs.identifier
    }

    private static func isGuarded(_ category: CleanupCategory) -> Bool {
        switch category {
        case .resultBundle, .archive, .deviceSupport:
            true
        default:
            false
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func contains(_ root: URL, _ target: URL) -> Bool {
        root == target || target.path.hasPrefix(root.path + "/")
    }
}
