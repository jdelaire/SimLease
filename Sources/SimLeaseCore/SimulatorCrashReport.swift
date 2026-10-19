import CryptoKit
import Foundation

public struct SimulatorCrashReport: Codable, Equatable, Sendable {
    public let incidentID: String
    public let deviceID: String
    public let occurredAt: Date
    public let launchedAt: Date
    public let signature: String
    public let processName: String

    static func parse(_ data: Data) -> SimulatorCrashReport? {
        guard data.count <= 5_000_000 else { return nil }
        let body: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["procName"] != nil {
            body = object
        } else {
            guard let newline = data.firstIndex(of: 10),
                  let object = try? JSONSerialization.jsonObject(with: data.suffix(from: data.index(after: newline))) as? [String: Any]
            else { return nil }
            body = object
        }
        guard let incident = body["incident"] as? String, !incident.isEmpty,
              let process = body["procName"] as? String, !process.isEmpty,
              let captured = body["captureTime"] as? String, let occurred = parseDate(captured),
              let launch = body["procLaunch"] as? String, let launched = parseDate(launch), launched <= occurred,
              let path = body["procPath"] as? String
        else { return nil }
        let parts = path.components(separatedBy: "/CoreSimulator/Devices/")
        guard parts.count == 2, let first = parts[1].split(separator: "/").first,
              let id = UUID(uuidString: String(first))?.uuidString,
              parts[1].hasPrefix(String(first) + "/data/") else { return nil }
        if let coalition = body["coalitionName"] as? String,
           coalition != "com.apple.CoreSimulator.SimDevice." + id { return nil }
        guard let exception = body["exception"] as? [String: Any],
              let type = exception["type"] as? String,
              let threads = body["threads"] as? [[String: Any]],
              let fault = body["faultingThread"] as? Int, threads.indices.contains(fault),
              let frames = threads[fault]["frames"] as? [[String: Any]],
              let images = body["usedImages"] as? [[String: Any]] else { return nil }
        let symbols = frames.compactMap { $0["symbol"] as? String }.prefix(1)
        guard !symbols.isEmpty else { return nil }
        let faultImage = frames.first(where: { $0["symbol"] is String })?["imageIndex"] as? Int
        let identities = images.enumerated().compactMap { index, image -> String? in
            let name = image["name"] as? String
            guard index == faultImage || name == process || name == process + ".debug.dylib" else { return nil }
            return image["uuid"] as? String
        }
        guard !identities.isEmpty else { return nil }
        let bundle = (body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String ?? process
        let key = ([bundle, process, type, exception["signal"] as? String ?? ""] + Set(identities).sorted() + symbols).joined(separator: "\n")
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return SimulatorCrashReport(incidentID: String(incident.prefix(128)), deviceID: id, occurredAt: occurred, launchedAt: launched, signature: hash, processName: String(process.prefix(128)))
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS Z"
        if let result = formatter.date(from: value) { return result }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: value)
    }
}

public final class CrashReportSource {
    private let directory: URL
    private var fingerprints: [String: String] = [:]

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")) {
        self.directory = directory
    }

    public func scan() throws -> [SimulatorCrashReport] {
        try autoreleasepool { try scanReports() }
    }

    private func scanReports() throws -> [SimulatorCrashReport] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        var candidates = [(URL, String, Date)]()
        for url in urls where url.pathExtension == "ips" {
            let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size <= 5_000_000, let date = info.contentModificationDate else { continue }
            let fingerprint = "\(size):\(date.timeIntervalSince1970)"
            if fingerprints[url.lastPathComponent] != fingerprint { candidates.append((url, fingerprint, date)) }
        }
        var reports = [SimulatorCrashReport]()
        for (url, fingerprint, _) in candidates.sorted(by: { $0.2 > $1.2 }).prefix(64) {
            guard let data = try? Data(contentsOf: url) else { continue }
            fingerprints[url.lastPathComponent] = fingerprint
            if let report = SimulatorCrashReport.parse(data) { reports.append(report) }
        }
        let present = Set(urls.map(\.lastPathComponent))
        fingerprints = fingerprints.filter { present.contains($0.key) }
        return reports
    }
}
