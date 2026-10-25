import Foundation

public struct ProcessSimulatorDeviceManager: SimulatorDeviceManaging {
    private let controller: SimulatorDeviceController
    private let bootTimeout: TimeInterval

    public init(environment: [String: String], xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"), bootTimeout: TimeInterval = 60) {
        controller = SimulatorDeviceController(environment: environment, xcrunURL: xcrunURL)
        self.bootTimeout = bootTimeout
    }

    public func inventory() throws -> [ManagedSimulatorDevice] {
        let json = try controller.command(["simctl", "list", "devices", "--json"])
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(json.utf8))
        return inventory.devices.flatMap { runtime, devices in
            devices.map { device in
                ManagedSimulatorDevice(id: device.udid.uppercased(), name: device.name, deviceType: device.deviceTypeIdentifier ?? "", runtime: runtime, dataPath: device.dataPath ?? "", state: device.state, available: device.isAvailable && device.deviceTypeIdentifier != nil && device.dataPath != nil)
            }
        }
    }

    public func pairedDeviceIDs() throws -> Set<String> {
        let json = try controller.command(["simctl", "list", "pairs", "--json"])
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let pairs = object["pairs"] as? [String: Any] else {
            throw DeviceManagementError.failed("simulator pair inventory could not be verified")
        }
        var ids = Set<String>()
        for value in pairs.values {
            guard let pair = value as? [String: Any] else { throw DeviceManagementError.failed("invalid simulator pair inventory") }
            for key in ["phone", "watch"] {
                guard let device = pair[key] as? [String: Any], let id = device["udid"] as? String, let uuid = UUID(uuidString: id) else {
                    throw DeviceManagementError.failed("simulator pairing could not be verified")
                }
                ids.insert(uuid.uuidString)
            }
        }
        return ids
    }

    public func create(name: String, deviceType: String, runtime: String) throws -> String {
        try run(["simctl", "create", name, deviceType, runtime]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func bootAndWait(_ id: String) throws {
        _ = try run(["simctl", "boot", id])
        _ = try run(["simctl", "bootstatus", id], observation: true, timeout: bootTimeout)
        guard try inventory().first(where: { $0.id == id })?.state == "Booted" else {
            throw DeviceManagementError.failed("boot completion was not verified for \(id)")
        }
    }

    public func shutdown(_ id: String) throws {
        guard try inventory().first(where: { $0.id == id })?.state != "Shutdown" else { return }
        _ = try run(["simctl", "shutdown", id])
        let deadline = Date(timeIntervalSinceNow: bootTimeout)
        while try inventory().first(where: { $0.id == id })?.state != "Shutdown" {
            guard Date() < deadline else { throw DeviceManagementError.unsettled("shutdown was not verified for \(id)") }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public func delete(_ id: String) throws { _ = try run(["simctl", "delete", id]) }

    public func servicePIDs(_ id: String) throws -> [String: Int32] {
        Self.parseServicePIDs(try run(["simctl", "spawn", id, "launchctl", "list"]))
    }

    static func parseServicePIDs(_ listing: String) -> [String: Int32] {
        var result: [String: Int32] = [:]
        for line in listing.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), pid > 0, Int32(fields[1]) != nil else { continue }
            result[String(fields[2])] = pid
        }
        return result
    }

    public func terminateApps(_ id: String) throws {
        let bundles = Self.runningApplications(try run(["simctl", "spawn", id, "launchctl", "list"]))
        for bundle in bundles { _ = try? run(["simctl", "terminate", id, bundle]) }
        let remaining = Self.runningApplications(try run(["simctl", "spawn", id, "launchctl", "list"]))
        guard remaining.isEmpty else { throw DeviceManagementError.failed("apps still running on \(id): \(remaining.sorted().joined(separator: ", "))") }
    }

    static func runningApplications(_ listing: String) -> Set<String> {
        Set(listing.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "UIKitApplication:") else { return nil }
            let bundle = line[range.upperBound...].prefix { $0 != "[" && !$0.isWhitespace }
            return bundle.isEmpty ? nil : String(bundle)
        })
    }

    private func run(_ arguments: [String], observation: Bool = false, timeout: TimeInterval? = nil) throws -> String {
        do { return try controller.command(arguments, timeout: timeout) }
        catch SimulatorTaskError.commandTimedOut(let detail) {
            if observation { throw DeviceManagementError.failed(detail) }
            throw DeviceManagementError.unsettled(detail)
        } catch SimulatorTaskError.commandFailed(let detail) {
            throw DeviceManagementError.failed(detail)
        }
    }

    private struct Inventory: Decodable { let devices: [String: [Device]] }
    private struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let deviceTypeIdentifier: String?
        let dataPath: String?
        let isAvailable: Bool
    }
}
