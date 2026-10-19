import Darwin
import Foundation

public protocol SimulatorDeviceControlling: Sendable {
    func states() throws -> [String: String]
    func shutdown(_ id: String) throws
}

public struct SimulatorDeviceController: SimulatorDeviceControlling {
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let xcrunURL: URL

    public init(environment: [String: String], timeout: TimeInterval = 20, xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun")) {
        self.environment = environment
        self.timeout = timeout
        self.xcrunURL = xcrunURL
    }

    public func states() throws -> [String: String] {
        let output = try command(["simctl", "list", "devices", "--json"])
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(output.utf8))
        return Dictionary(uniqueKeysWithValues: inventory.devices.values.flatMap { $0 }
            .map { ($0.udid.uppercased(), $0.state) })
    }

    public func shutdown(_ id: String) throws {
        guard let initial = try states()[id], initial != "Shutdown" else { return }
        _ = try command(["simctl", "shutdown", id])
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let state = try states()[id]
            if state == nil || state == "Shutdown" { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw SimulatorTaskError.commandTimedOut("shutdown \(id)")
    }

    func command(_ arguments: [String], timeout limit: TimeInterval? = nil) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("stdout")
        let errorURL = root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = xcrunURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let reference = ProcessReference.capture(pid: process.processIdentifier)
        let deadline = Date(timeIntervalSinceNow: limit ?? timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        if process.isRunning {
            if reference?.state == .matching { process.terminate() }
            let killDeadline = Date(timeIntervalSinceNow: 1)
            while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.03) }
            if process.isRunning, reference?.state == .matching {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            let finalDeadline = Date(timeIntervalSinceNow: 3)
            while process.isRunning && Date() < finalDeadline { Thread.sleep(forTimeInterval: 0.03) }
            guard !process.isRunning else { throw SimulatorTaskError.unverifiedProcess(process.processIdentifier) }
            process.waitUntilExit()
            throw SimulatorTaskError.commandTimedOut(arguments.joined(separator: " "))
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else {
            throw DeviceManagementError.unsettled("simctl terminated by signal \(process.terminationStatus)")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            throw SimulatorTaskError.commandFailed("simctl failed: \(message)")
        }
        return String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
    }

    private struct Inventory: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let state: String
    }
}
