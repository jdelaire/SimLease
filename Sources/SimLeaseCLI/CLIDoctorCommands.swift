import Foundation
import SimLeaseCore

struct DoctorCheck: Codable, Equatable {
    let name: String
    let ok: Bool
    let detail: String
}

struct DoctorReport: Codable, Equatable {
    let ok: Bool
    let checks: [DoctorCheck]
}

extension SimLeaseCLI {
    static func runDoctor(
        json: Bool,
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) throws -> Int32 {
        let report = doctorReport(
            arguments: arguments,
            environment: environment,
            configuration: configuration
        )
        if json {
            try writeJSON(report, configuration: configuration)
        } else {
            for check in report.checks {
                configuration.standardOutput(
                    "\(check.ok ? "ok" : "issue"): \(check.name): \(check.detail)\n"
                )
            }
        }
        return report.ok ? 0 : 76
    }

    static func doctorReport(
        arguments: [String],
        environment: [String: String],
        configuration: CLIConfiguration
    ) -> DoctorReport {
        let fileManager = FileManager.default
        guard let invoked = arguments.first,
              invoked.contains("/"),
              !invoked.isEmpty else {
            return DoctorReport(ok: false, checks: [
                DoctorCheck(
                    name: "shims-directory",
                    ok: false,
                    detail: "cannot locate shims directory from invocation path"
                ),
            ])
        }
        let shimsDir = URL(fileURLWithPath: invoked)
            .deletingLastPathComponent()
            .appendingPathComponent("shims", isDirectory: true)
            .standardizedFileURL

        var checks = [DoctorCheck]()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: shimsDir.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            checks.append(DoctorCheck(
                name: "shims-directory",
                ok: true,
                detail: shimsDir.path
            ))
        } else {
            checks.append(DoctorCheck(
                name: "shims-directory",
                ok: false,
                detail: "missing directory \(shimsDir.path)"
            ))
        }

        let pathValue = environment["PATH"] ?? ""
        let directories = pathValue
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { component in
                component.isEmpty
                    ? fileManager.currentDirectoryPath
                    : String(component)
            }
            .map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .standardizedFileURL.path
            }
        if directories.first == shimsDir.path {
            checks.append(DoctorCheck(
                name: "path-order",
                ok: true,
                detail: "shims directory is first on PATH"
            ))
        } else if directories.contains(shimsDir.path) {
            checks.append(DoctorCheck(
                name: "path-order",
                ok: false,
                detail: "shims directory is on PATH but not first; move \(shimsDir.path) to the front"
            ))
        } else {
            checks.append(DoctorCheck(
                name: "path-order",
                ok: false,
                detail: "shims directory missing from PATH; prepend \(shimsDir.path)"
            ))
        }

        for tool in ["xcodebuild", "xcrun", "axe"] {
            checks.append(doctorToolCheck(
                tool: tool,
                path: pathValue,
                shimsDir: shimsDir
            ))
        }

        if let laneFile = environment["SIMLEASE_LANE_FILE"],
           !laneFile.isEmpty {
            checks.append(doctorLaneCheck(
                path: laneFile,
                configuration: configuration
            ))
        } else {
            checks.append(DoctorCheck(
                name: "lane",
                ok: true,
                detail: "no lane active"
            ))
        }

        return DoctorReport(
            ok: checks.allSatisfy(\.ok),
            checks: checks
        )
    }

    private static func doctorToolCheck(
        tool: String,
        path: String,
        shimsDir: URL
    ) -> DoctorCheck {
        let resolved: URL
        do {
            resolved = try ExecutableResolver.resolve(
                name: tool,
                path: path,
                excluding: URL(fileURLWithPath: "/__simlease_no_exclusion__")
            )
        } catch {
            return DoctorCheck(
                name: "tool:\(tool)",
                ok: true,
                detail: "not installed; nothing to intercept"
            )
        }
        if resolved.deletingLastPathComponent().standardizedFileURL == shimsDir {
            return DoctorCheck(
                name: "tool:\(tool)",
                ok: true,
                detail: "intercepted via shims"
            )
        }
        return DoctorCheck(
            name: "tool:\(tool)",
            ok: false,
            detail: "resolves to \(resolved.path), bypasses the lease; call it through \(shimsDir.path)"
        )
    }

    private static func doctorLaneCheck(
        path: String,
        configuration: CLIConfiguration
    ) -> DoctorCheck {
        do {
            let store = try LaneStore(paths: configuration.paths)
            let descriptor = try store.readDescriptor(
                at: URL(fileURLWithPath: path)
            )
            return DoctorCheck(
                name: "lane",
                ok: true,
                detail: "active \(descriptor.laneID) (\(descriptor.udid))"
            )
        } catch {
            return DoctorCheck(
                name: "lane",
                ok: false,
                detail: "SIMLEASE_LANE_FILE is set but unreadable: \(error)"
            )
        }
    }
}
