import Foundation
import Darwin

public struct LeaseIdentity: Equatable, Sendable {
    public let pid: Int32
    public let cwd: String
    public let project: String
    public let command: [String]
    public let source: LeaseSource
    public let threadID: String?
    public let threadTitle: String?

    public init(
        pid: Int32,
        cwd: String,
        project: String,
        command: [String],
        source: LeaseSource,
        threadID: String?,
        threadTitle: String?
    ) {
        self.pid = pid
        self.cwd = cwd
        self.project = project
        self.command = command
        self.source = source
        self.threadID = threadID
        self.threadTitle = threadTitle
    }

    public static func resolve(
        environment: [String: String],
        cwd: String,
        command: [String],
        store: MetadataStore,
        pid: Int32 = getpid()
    ) throws -> LeaseIdentity {
        let threadID = environment["CODEX_THREAD_ID"]
        let title = threadID.flatMap { try? store.threadName(id: $0) }
        let normalizedPath = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let project = URL(fileURLWithPath: normalizedPath).lastPathComponent

        return LeaseIdentity(
            pid: pid,
            cwd: cwd,
            project: project,
            command: command,
            source: threadID == nil ? .terminal : .codex,
            threadID: threadID,
            threadTitle: title
        )
    }
}
