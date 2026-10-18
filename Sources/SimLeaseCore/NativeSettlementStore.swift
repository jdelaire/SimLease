import Foundation

public struct NativeSettlementStore: Sendable {
    private struct Acknowledgment: Codable {
        let sessionID: String
        let token: String
    }

    private let paths: LeasePaths

    public init(paths: LeasePaths) { self.paths = paths }

    public func acknowledge(_ record: SimulatorTaskRecord) throws {
        let file = try location(record)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Acknowledgment(sessionID: record.externalSessionID!, token: record.token))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public func isAcknowledged(_ record: SimulatorTaskRecord) throws -> Bool {
        let file = try location(record)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let value = try JSONDecoder().decode(Acknowledgment.self, from: Data(contentsOf: file))
        return value.sessionID == record.externalSessionID && value.token == record.token
    }

    public func remove(_ record: SimulatorTaskRecord) throws {
        let file = try location(record)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func location(_ record: SimulatorTaskRecord) throws -> URL {
        guard let value = record.externalSessionID, let id = UUID(uuidString: value),
              let token = UUID(uuidString: record.token)
        else { throw SimulatorTaskError.commandFailed("invalid native session identity") }
        return paths.root.appendingPathComponent("native-acknowledgments", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).\(token.uuidString).json")
    }
}
