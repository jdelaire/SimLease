import CryptoKit
import Foundation

public struct SimulatorCrashReport: Codable, Equatable, Sendable {
    public let incidentID: String
    public let deviceID: String
    public let occurredAt: Date
    public let launchedAt: Date
    public let signature: String
    public let processName: String
    public var isCriticalSystemService: Bool? = nil
    public var kind: SimulatorCrashKind? = nil

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
        let prefix = "com.apple.CoreSimulator.SimDevice."
        let id: String
        let runtimeService: Bool
        if parts.count > 1 {
            guard parts.count == 2, let first = parts[1].split(separator: "/").first,
                  let device = UUID(uuidString: String(first))?.uuidString,
                  parts[1].hasPrefix(String(first) + "/data/") else { return nil }
            if let coalition = body["coalitionName"] as? String, coalition != prefix + device { return nil }
            id = device
            runtimeService = false
        } else {
            guard body["parentProc"] as? String == "launchd_sim",
                  let coalition = body["coalitionName"] as? String, coalition.hasPrefix(prefix),
                  let device = UUID(uuidString: String(coalition.dropFirst(prefix.count)))?.uuidString,
                  coalition == prefix + device else { return nil }
            id = device
            runtimeService = true
        }
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
        let systemIdentifier = (body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String ?? body["codeSigningID"] as? String ?? ""
        let critical = runtimeService && (
            (process == "PosterBoard" && bundle == "com.apple.PosterBoard" && path.hasSuffix("/PosterBoard.app/PosterBoard"))
                || (process == "SpringBoard" && bundle == "com.apple.springboard" && path.hasSuffix("/SpringBoard.app/SpringBoard"))
        )
        let key = ([bundle, process, type, exception["signal"] as? String ?? ""] + Set(identities).sorted() + symbols).joined(separator: "\n")
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let background = runtimeService && (
            (process == "intelligencetasksd" && systemIdentifier == "com.apple.intelligencetasksd" && path.hasSuffix("/IntelligenceTasksEngine.framework/Support/intelligencetasksd"))
                || (process == "AppIntentsLiveEntityService" && systemIdentifier == "com.apple.appintents.LiveEntityService" && path.hasSuffix("/AppIntentsLiveEntitySupport.framework/XPCServices/AppIntentsLiveEntityService.xpc/AppIntentsLiveEntityService"))
        )
        let kind: SimulatorCrashKind = critical ? .criticalInfrastructure : (background ? .backgroundService : (runtimeService ? .unknown : .application))
        return SimulatorCrashReport(incidentID: String(incident.prefix(128)), deviceID: id, occurredAt: occurred, launchedAt: launched, signature: hash, processName: String(process.prefix(128)), isCriticalSystemService: critical ? true : nil, kind: kind)
    }

    static func isProvenUnrelated(_ data: Data) -> Bool {
        let body: [String: Any]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = object
        } else {
            guard let newline = data.firstIndex(of: 10),
                  let header = try? JSONSerialization.jsonObject(with: data.prefix(upTo: newline)) as? [String: Any],
                  header["platform"] as? Int != 7,
                  let object = try? JSONSerialization.jsonObject(with: data.suffix(from: data.index(after: newline))) as? [String: Any] else { return false }
            body = object
        }
        guard body["platform"] as? Int != 7, body["procName"] is String, let path = body["procPath"] as? String,
              path.hasPrefix("/"), !path.contains("/CoreSimulator/Devices/"),
              body["parentProc"] as? String != "launchd_sim",
              !(body["coalitionName"] as? String ?? "").hasPrefix("com.apple.CoreSimulator.SimDevice.") else { return false }
        return true
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
    private let paths: LeasePaths?
    private var fingerprints: [String: String] = [:]
    private var scanned: [String: String] = [:]
    private var present = Set<String>()
    private var retries: [String: Retry] = [:]
    private var retryUpdates: [String: Retry] = [:]
    private var eventTimes: [String: Date] = [:]

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"), paths: LeasePaths? = nil) {
        self.directory = directory
        self.paths = paths
    }

    public private(set) var evidenceComplete = false

    public func inspect(store: CrashLoopStore, now: Date? = nil) throws -> [CrashLoopTrigger] {
        if let paths {
            let checkpoint = try RecoveryFile.read(Checkpoint.self, at: checkpointURL(paths))
            fingerprints = checkpoint?.directory == directory.standardizedFileURL.path ? checkpoint!.fingerprints : [:]
            retries = checkpoint?.directory == directory.standardizedFileURL.path ? checkpoint!.retries ?? [:] : [:]
        }
        let previous = fingerprints
        do {
            let reports = try scan(now: now ?? Date())
            let observedAt = now ?? Date()
            for (name, date) in eventTimes where date > observedAt {
                if let fingerprint = scanned.removeValue(forKey: name) {
                    fingerprints[name] = previous[name]
                    retryUpdates[name] = Retry(fingerprint: fingerprint, after: date)
                }
            }
            let triggers = try store.ingest(reports, now: observedAt)
            if let paths {
                try SharedStateLock.withLock(paths) {
                    let url = checkpointURL(paths)
                    let previous = try RecoveryFile.read(Checkpoint.self, at: url)
                    var merged = previous?.directory == directory.standardizedFileURL.path ? previous!.fingerprints : [:]
                    var deferred = previous?.directory == directory.standardizedFileURL.path ? previous!.retries ?? [:] : [:]
                    merged.merge(scanned) { _, latest in latest }
                    merged = merged.filter { present.contains($0.key) }
                    deferred.merge(retryUpdates) { _, latest in latest }
                    deferred = deferred.filter { present.contains($0.key) && scanned[$0.key] == nil }
                    let checkpoint = Checkpoint(directory: directory.standardizedFileURL.path, fingerprints: merged, retries: deferred.isEmpty ? nil : deferred)
                    if checkpoint != previous { try RecoveryFile.write(checkpoint, at: url) }
                }
            }
            evidenceComplete = evidenceComplete && retryUpdates.isEmpty && !retries.contains { present.contains($0.key) && scanned[$0.key] == nil }
            return triggers
        } catch {
            fingerprints = previous
            throw error
        }
    }

    public func scan(now: Date = Date()) throws -> [SimulatorCrashReport] {
        try autoreleasepool { try scanReports(now: now) }
    }

    private func scanReports(now: Date) throws -> [SimulatorCrashReport] {
        evidenceComplete = false
        scanned.removeAll(keepingCapacity: true)
        retryUpdates.removeAll(keepingCapacity: true)
        eventTimes.removeAll(keepingCapacity: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        var candidates = [(URL, String, Date, Int, Bool)]()
        var uncovered = false
        for url in urls where url.pathExtension == "ips" {
            let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            guard let size = info.fileSize, size <= 5_000_000, let date = info.contentModificationDate else { uncovered = true; continue }
            let fingerprint = "\(size):\(date.timeIntervalSince1970)"
            if let retry = retries[url.lastPathComponent], retry.fingerprint == fingerprint, retry.after > now { continue }
            if fingerprints[url.lastPathComponent] != fingerprint {
                candidates.append((url, fingerprint, date, size, retries[url.lastPathComponent]?.fingerprint == fingerprint))
            }
        }
        var reports = [SimulatorCrashReport]()
        var bytes = 0
        let ordered = candidates.sorted { $0.4 == $1.4 ? $0.2 > $1.2 : !$0.4 }
        for (url, fingerprint, _, size, _) in ordered.prefix(64) {
            guard bytes < 16_000_000, bytes + size <= 16_000_000 else { break }
            let data: Data
            do {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                data = try file.read(upToCount: min(5_000_001, 16_000_000 - bytes)) ?? Data()
                bytes += data.count
            } catch {
                retryUpdates[url.lastPathComponent] = Retry(fingerprint: fingerprint, after: now.addingTimeInterval(30))
                continue
            }
            guard data.count == size else {
                retryUpdates[url.lastPathComponent] = Retry(fingerprint: fingerprint, after: now.addingTimeInterval(30))
                continue
            }
            if let report = SimulatorCrashReport.parse(data) {
                reports.append(report)
                eventTimes[url.lastPathComponent] = report.occurredAt
            } else if !SimulatorCrashReport.isProvenUnrelated(data) {
                retryUpdates[url.lastPathComponent] = Retry(fingerprint: fingerprint, after: now.addingTimeInterval(30))
                continue
            }
            fingerprints[url.lastPathComponent] = fingerprint
            scanned[url.lastPathComponent] = fingerprint
        }
        evidenceComplete = !uncovered && candidates.count == scanned.count && retryUpdates.isEmpty
        present = Set(urls.map(\.lastPathComponent))
        fingerprints = fingerprints.filter { present.contains($0.key) }
        retries.merge(retryUpdates) { _, latest in latest }
        return reports
    }

    private func checkpointURL(_ paths: LeasePaths) -> URL { paths.root.appendingPathComponent("crash-report-progress-v2.json") }

    private struct Checkpoint: Codable, Equatable {
        let directory: String
        let fingerprints: [String: String]
        let retries: [String: Retry]?
    }

    private struct Retry: Codable, Equatable {
        let fingerprint: String
        let after: Date
    }
}
