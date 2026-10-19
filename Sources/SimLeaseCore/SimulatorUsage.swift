import Foundation

public struct SimulatorUsage: Codable, Equatable, Sendable, Identifiable {
    public enum Reservation: String, Codable, Sendable {
        case owned
        case borrowed
        case unreserved
    }

    public let id: String
    public let name: String
    public let runtime: String
    public let state: String
    public let reservation: Reservation

    public init(id: String, name: String, runtime: String, state: String, reservation: Reservation) {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.state = state
        self.reservation = reservation
    }

    public static func build(inventory: [ManagedSimulatorDevice], task: SimulatorTaskRecord?, relevantIDs: Set<String> = []) -> [SimulatorUsage] {
        let owned = Set((task?.ownedDeviceIDs ?? []).map { $0.uppercased() })
        let reserved = Set((task?.deviceIDs ?? []).map { $0.uppercased() })
        let relevant = Set(relevantIDs.map { $0.uppercased() })
        let devices = Dictionary(inventory.map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var usage = devices.compactMap { id, device -> SimulatorUsage? in
            let reservation: Reservation = owned.contains(id) ? .owned : reserved.contains(id) ? .borrowed : .unreserved
            guard reservation != .unreserved || device.state != "Shutdown" || relevant.contains(id) else { return nil }
            return SimulatorUsage(id: id, name: device.name, runtime: runtimeName(device.runtime), state: device.state, reservation: reservation)
        }
        for id in reserved.union(owned) where devices[id] == nil {
            usage.append(SimulatorUsage(id: id, name: "Unknown simulator", runtime: "", state: "Missing", reservation: owned.contains(id) ? .owned : .borrowed))
        }
        return usage.sorted { ($0.reservation == .unreserved ? 1 : 0, $0.name, $0.id) < ($1.reservation == .unreserved ? 1 : 0, $1.name, $1.id) }
    }

    static func runtimeName(_ identifier: String) -> String {
        let parts = (identifier.components(separatedBy: "SimRuntime.").last ?? identifier).split(separator: "-").map(String.init)
        guard let platform = parts.first else { return identifier }
        let version = parts.dropFirst().prefix { Int($0) != nil }
        return version.isEmpty ? platform : "\(platform) \(version.joined(separator: "."))"
    }
}
