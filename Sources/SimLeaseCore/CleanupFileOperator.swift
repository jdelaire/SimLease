import Foundation

public enum CleanupFileOperationError: Error, Equatable {
    case targetIsAllowedRoot(String)
    case targetOutsideAllowedRoots(String)
}

public protocol CleanupFileOperating: Sendable {
    func delete(_ url: URL) throws
    func trash(_ url: URL) throws
}

public final class CleanupFileOperator: CleanupFileOperating, @unchecked Sendable {
    private let allowedRoots: [URL]
    private let fileManager: FileManager
    private let trashHandler: (URL) throws -> Void

    public init(
        allowedRoots: [URL],
        fileManager: FileManager = .default
    ) {
        self.allowedRoots = allowedRoots.map(Self.canonical)
        self.fileManager = fileManager
        trashHandler = { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    init(
        allowedRoots: [URL],
        fileManager: FileManager = .default,
        trashHandler: @escaping (URL) throws -> Void
    ) {
        self.allowedRoots = allowedRoots.map(Self.canonical)
        self.fileManager = fileManager
        self.trashHandler = trashHandler
    }

    public func delete(_ url: URL) throws {
        try fileManager.removeItem(at: validated(url))
    }

    public func trash(_ url: URL) throws {
        try trashHandler(validated(url))
    }

    private func validated(_ url: URL) throws -> URL {
        let target = Self.canonical(url)
        if allowedRoots.contains(target) {
            throw CleanupFileOperationError.targetIsAllowedRoot(target.path)
        }
        guard allowedRoots.contains(where: { Self.contains($0, target) }) else {
            throw CleanupFileOperationError.targetOutsideAllowedRoots(target.path)
        }
        return target
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func contains(_ root: URL, _ target: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return target.path.hasPrefix(rootPath)
    }
}
