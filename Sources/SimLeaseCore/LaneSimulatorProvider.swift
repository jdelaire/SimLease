import Foundation

public struct LaneRuntime: Codable, Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let version: String
    public let isAvailable: Bool

    public init(identifier: String, name: String, version: String, isAvailable: Bool) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.isAvailable = isAvailable
    }
}

public struct LaneDeviceType: Codable, Equatable, Sendable {
    public let identifier: String
    public let name: String

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

public struct LaneSimulatorDevice: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtimeIdentifier: String
    public let deviceTypeIdentifier: String
    public let dataPath: String?

    public init(
        udid: String,
        name: String,
        state: String,
        runtimeIdentifier: String,
        deviceTypeIdentifier: String,
        dataPath: String?
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.dataPath = dataPath
    }
}

public struct LaneSimulatorInventory: Equatable, Sendable {
    public let runtimes: [LaneRuntime]
    public let deviceTypes: [LaneDeviceType]
    public let devices: [LaneSimulatorDevice]

    public init(
        runtimes: [LaneRuntime],
        deviceTypes: [LaneDeviceType],
        devices: [LaneSimulatorDevice]
    ) {
        self.runtimes = runtimes
        self.deviceTypes = deviceTypes
        self.devices = devices
    }

    public func resolveRuntime(_ requested: String) throws -> LaneRuntime {
        let available = runtimes.filter(\.isAvailable)
        if requested.localizedCaseInsensitiveCompare("latest") == .orderedSame {
            guard let latest = available.max(by: {
                versionIsLess($0.version, than: $1.version)
            }) else {
                throw LaneServiceError.runtimeUnavailable(
                    requested: requested,
                    available: []
                )
            }
            return latest
        }
        let matches = available.filter {
            $0.identifier == requested
                || $0.name.localizedCaseInsensitiveCompare(requested) == .orderedSame
        }
        guard matches.count == 1, let match = matches.first else {
            throw LaneServiceError.runtimeUnavailable(
                requested: requested,
                available: available.map(\.identifier).sorted()
            )
        }
        return match
    }

    public func resolveDeviceType(_ requested: String) throws -> LaneDeviceType {
        let matches = deviceTypes.filter {
            $0.identifier == requested
                || $0.name.localizedCaseInsensitiveCompare(requested) == .orderedSame
        }
        guard matches.count == 1, let match = matches.first else {
            throw LaneServiceError.deviceTypeUnavailable(
                requested: requested,
                available: deviceTypes.map(\.identifier).sorted()
            )
        }
        return match
    }

}

public enum LaneSimulatorProviderError: Error, Equatable {
    case commandFailed(arguments: [String], code: Int32, stderr: String)
    case invalidInventory(String)
    case invalidCreatedUDID(String)
}

public protocol LaneSimulatorProviding: Sendable {
    func inventory() throws -> LaneSimulatorInventory
    func createDevice(name: String, deviceTypeID: String, runtimeID: String) throws -> String
    func shutdownDevice(udid: String) throws
    func deleteDevice(udid: String) throws
}

public final class ProcessLaneSimulatorProvider:
    LaneSimulatorProviding,
    @unchecked Sendable
{
    private let runner: any CleanupCommandRunning
    private let xcrunURL: URL
    private let environment: [String: String]

    public init(
        runner: any CleanupCommandRunning = ProcessCleanupCommandRunner(),
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.xcrunURL = xcrunURL
        self.environment = environment
    }

    public func inventory() throws -> LaneSimulatorInventory {
        struct RuntimeEnvelope: Decodable { let runtimes: [LaneRuntime] }
        struct DeviceTypeEnvelope: Decodable { let devicetypes: [LaneDeviceType] }
        struct DeviceEnvelope: Decodable {
            struct Device: Decodable {
                let udid: String
                let name: String
                let state: String
                let deviceTypeIdentifier: String
                let dataPath: String?
            }
            let devices: [String: [Device]]
        }

        let runtimeOutput = try run(["simctl", "list", "runtimes", "-j"])
        let typeOutput = try run(["simctl", "list", "devicetypes", "-j"])
        let deviceOutput = try run(["simctl", "list", "devices", "-j"])
        do {
            let runtimes = try JSONDecoder.simLease.decode(
                RuntimeEnvelope.self,
                from: Data(runtimeOutput.utf8)
            ).runtimes.filter(\.isAvailable).sorted {
                versionIsLess($0.version, than: $1.version)
            }
            let deviceTypes = try JSONDecoder.simLease.decode(
                DeviceTypeEnvelope.self,
                from: Data(typeOutput.utf8)
            ).devicetypes.sorted { $0.identifier < $1.identifier }
            let envelope = try JSONDecoder.simLease.decode(
                DeviceEnvelope.self,
                from: Data(deviceOutput.utf8)
            )
            let devices = envelope.devices.flatMap { runtimeID, devices in
                devices.map {
                    LaneSimulatorDevice(
                        udid: $0.udid,
                        name: $0.name,
                        state: $0.state,
                        runtimeIdentifier: runtimeID,
                        deviceTypeIdentifier: $0.deviceTypeIdentifier,
                        dataPath: $0.dataPath
                    )
                }
            }.sorted { $0.udid < $1.udid }
            return LaneSimulatorInventory(
                runtimes: runtimes,
                deviceTypes: deviceTypes,
                devices: devices
            )
        } catch {
            throw LaneSimulatorProviderError.invalidInventory(String(describing: error))
        }
    }

    public func createDevice(
        name: String,
        deviceTypeID: String,
        runtimeID: String
    ) throws -> String {
        let output = try run(["simctl", "create", name, deviceTypeID, runtimeID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty,
              output.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "-")
                  ).contains($0)
              })
        else {
            throw LaneSimulatorProviderError.invalidCreatedUDID(output)
        }
        return output
    }

    public func shutdownDevice(udid: String) throws {
        _ = try run(["simctl", "shutdown", udid])
    }

    public func deleteDevice(udid: String) throws {
        _ = try run(["simctl", "delete", udid])
    }

    private func run(_ arguments: [String]) throws -> String {
        var childEnvironment = environment
        childEnvironment["SIMLEASE_HELD"] = "1"
        let output = try runner.run(
            executable: xcrunURL,
            arguments: arguments,
            environment: childEnvironment
        )
        guard output.exitCode == 0 else {
            throw LaneSimulatorProviderError.commandFailed(
                arguments: arguments,
                code: output.exitCode,
                stderr: output.stderr
            )
        }
        return output.stdout
    }
}

private func versionIsLess(_ lhs: String, than rhs: String) -> Bool {
    let left = lhs.split(separator: ".").map { Int($0) ?? -1 }
    let right = rhs.split(separator: ".").map { Int($0) ?? -1 }
    let count = max(left.count, right.count)
    for index in 0..<count {
        let l = index < left.count ? left[index] : 0
        let r = index < right.count ? right[index] : 0
        if l != r { return l < r }
    }
    return false
}
