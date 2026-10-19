import Foundation

enum RecoveryFile {
    static func read<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value? {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    static func write<Value: Encodable>(_ value: Value, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }
}
