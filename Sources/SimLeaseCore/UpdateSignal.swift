import Foundation

public enum UpdateSignal {
    public static let request = Notification.Name("com.jdelaire.simlease.update.request")
    public static let acknowledge = Notification.Name("com.jdelaire.simlease.update.acknowledge")
    public static let requestLifetime: TimeInterval = 4

    public static func requestToken(id: String = UUID().uuidString, sentAt: Date = Date()) -> String {
        "\(id)|\(sentAt.timeIntervalSince1970)"
    }

    public static func isFresh(_ token: String, now: Date = Date()) -> Bool {
        guard let sent = token.split(separator: "|").last.flatMap({ TimeInterval($0) }) else { return false }
        let age = now.timeIntervalSince1970 - sent
        return age >= -1 && age < requestLifetime
    }
}
