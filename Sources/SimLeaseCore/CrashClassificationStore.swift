import Foundation

struct CrashClassificationStore {
    let paths: LeasePaths
    private var url: URL { paths.root.appendingPathComponent("crash-classifications.json") }

    static func matches(_ first: SimulatorCrashReport, _ second: SimulatorCrashReport) -> Bool {
        first.incidentID == second.incidentID && first.deviceID == second.deviceID && first.signature == second.signature
            && first.occurredAt == second.occurredAt && first.launchedAt == second.launchedAt && first.processName == second.processName
    }

    func overlay(_ reports: [SimulatorCrashReport]) throws -> [SimulatorCrashReport] {
        let metadata = try read()
        return reports.map { report in
            guard report.kind == nil, let proof = metadata[report.incidentID], proof.kind != nil,
                  Self.matches(report, proof), report.isCriticalSystemService != true || proof.isCriticalSystemService == true else { return report }
            var result = report
            result.kind = proof.kind
            result.isCriticalSystemService = proof.isCriticalSystemService
            return result
        }
    }

    func persist(_ reports: [SimulatorCrashReport]) throws {
        let previous = try read()
        var retained = [String: SimulatorCrashReport]()
        for report in reports.sorted(by: { $0.occurredAt < $1.occurredAt }).suffix(512) {
            if report.kind != nil {
                retained[report.incidentID] = report
            } else if let proof = previous[report.incidentID], Self.matches(report, proof) {
                retained[report.incidentID] = proof
            }
        }
        if retained != previous { try RecoveryFile.write(retained, at: url) }
    }

    private func read() throws -> [String: SimulatorCrashReport] {
        try RecoveryFile.read([String: SimulatorCrashReport].self, at: url) ?? [:]
    }
}
