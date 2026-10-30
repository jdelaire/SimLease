import CryptoKit
import Darwin
import Foundation

public enum DeviceDataInventoryError: Error, Equatable {
    case unsafeTarget(String)
}

public enum DeviceDataInventory {
    static let namedTargets: Set<String> = ["Caches", "tmp"]
    static let fixedTargets = ["Library/Logs", "var/log", "var/db/diagnostics", "var/db/uuidtext"]
    static let protectedNames: Set<String> = ["Documents", "Mobile Documents", "Media", "MobileAsset"]

    public static func targets(dataPath: URL) throws -> [URL] {
        let root = dataPath.standardizedFileURL
        guard isRealDirectory(root.path) else { return [] }
        var found = [String]()
        var stack = [""]
        while let relative = stack.popLast() {
            let directory = relative.isEmpty ? root.path : root.path + "/" + relative
            for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
                let child = relative.isEmpty ? name : relative + "/" + name
                guard isRealDirectory(root.path + "/" + child), child != "Containers/Bundle", !protectedNames.contains(name) else { continue }
                if namedTargets.contains(name) { found.append(child) } else { stack.append(child) }
            }
        }
        for fixed in fixedTargets where !found.contains(where: { fixed == $0 || fixed.hasPrefix($0 + "/") }) {
            if safeChain(fixed, under: root.path) { found.append(fixed) }
        }
        return found.sorted().map { root.appendingPathComponent($0, isDirectory: true) }
    }

    public static func measure(_ targets: [URL], dataPath: URL) throws -> (sizeBytes: Int64, digest: String) {
        let root = dataPath.standardizedFileURL.path
        var size: Int64 = 0
        var lines = [String]()
        for target in targets {
            let relative = try relativePath(target, under: root)
            var stack = [relative]
            while let current = stack.popLast() {
                var info = stat()
                guard lstat(root + "/" + current, &info) == 0 else { continue }
                size += Int64(info.st_blocks) * 512
                lines.append("\(current)\u{0}\(info.st_mode)\u{0}\(info.st_size)\u{0}\(info.st_ino)\u{0}\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
                if info.st_mode & S_IFMT == S_IFDIR {
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + current)) ?? [] { stack.append(current + "/" + name) }
                }
            }
        }
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return (size, digest)
    }

    public static func clear(_ targets: [URL], within dataPath: URL) throws {
        let root = dataPath.standardizedFileURL.path
        for target in targets {
            let relative = try relativePath(target, under: root)
            guard safeChain(relative, under: root) else { throw DeviceDataInventoryError.unsafeTarget(target.path) }
            let directory = root + "/" + relative
            for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
                try FileManager.default.removeItem(atPath: directory + "/" + name)
            }
        }
    }

    private static func relativePath(_ target: URL, under root: String) throws -> String {
        let path = target.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { throw DeviceDataInventoryError.unsafeTarget(path) }
        let relative = String(path.dropFirst(root.count + 1))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw DeviceDataInventoryError.unsafeTarget(path)
        }
        return relative
    }

    private static func safeChain(_ relative: String, under root: String) -> Bool {
        guard isRealDirectory(root) else { return false }
        var current = root
        for component in relative.split(separator: "/") {
            current += "/" + component
            guard isRealDirectory(current) else { return false }
        }
        return true
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
