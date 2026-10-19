import Foundation

public struct SimulatorUsage: Codable, Equatable, Sendable, Identifiable {
    public enum Reservation: String, Codable, Sendable {
        case owned
        case borrowed
        case warm
        case unreserved
    }

    public let id: String
    public let name: String
    public let runtime: String
    public let state: String
    public let reservation: Reservation
    public let warmSince: Date?
    public let runtimeStale: Bool?
    public let lane: Int?

    public init(id: String, name: String, runtime: String, state: String, reservation: Reservation, warmSince: Date? = nil, runtimeStale: Bool? = nil, lane: Int? = nil) {
        self.lane = lane
        self.runtimeStale = runtimeStale
        self.warmSince = warmSince
        self.id = id
        self.name = name
        self.runtime = runtime
        self.state = state
        self.reservation = reservation
    }

    public static func build(inventory: [ManagedSimulatorDevice], task: SimulatorTaskRecord?, relevantIDs: Set<String> = [], warm: [String: Date] = [:], staleRuntimes: Set<String> = []) -> [SimulatorUsage] {
        build(inventory: inventory, tasks: task.map { [(0, $0)] } ?? [], relevantIDs: relevantIDs, warm: warm, staleRuntimes: staleRuntimes)
    }

    public static func build(inventory: [ManagedSimulatorDevice], tasks: [(Int, SimulatorTaskRecord)], relevantIDs: Set<String> = [], warm: [String: Date] = [:], staleRuntimes: Set<String> = []) -> [SimulatorUsage] {
        let owned = Set(tasks.flatMap { $0.1.ownedDeviceIDs.map { $0.uppercased() } })
        let reserved = Set(tasks.flatMap { $0.1.deviceIDs.map { $0.uppercased() } })
        var laneOf = [String: Int]()
        for (lane, record) in tasks { for id in record.deviceIDs { laneOf[id.uppercased()] = lane } }
        let relevant = Set(relevantIDs.map { $0.uppercased() })
        let devices = Dictionary(inventory.map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var usage = devices.compactMap { id, device -> SimulatorUsage? in
            let since = device.state == "Booted" ? warm[id] : nil
            let reservation: Reservation = owned.contains(id) ? .owned : reserved.contains(id) ? .borrowed : since != nil ? .warm : .unreserved
            guard reservation != .unreserved || device.state != "Shutdown" || relevant.contains(id) else { return nil }
            return SimulatorUsage(id: id, name: device.name, runtime: runtimeName(device.runtime), state: device.state, reservation: reservation, warmSince: reservation == .warm ? since : nil, runtimeStale: staleRuntimes.contains(device.runtime) ? true : nil, lane: laneOf[id])
        }
        for id in reserved.union(owned) where devices[id] == nil {
            usage.append(SimulatorUsage(id: id, name: "Unknown simulator", runtime: "", state: "Missing", reservation: owned.contains(id) ? .owned : .borrowed, lane: laneOf[id]))
        }
        return usage.sorted { (rank($0.reservation), $0.name, $0.id) < (rank($1.reservation), $1.name, $1.id) }
    }

    private static func rank(_ reservation: Reservation) -> Int {
        switch reservation {
        case .owned, .borrowed: 0
        case .warm: 1
        case .unreserved: 2
        }
    }

    public static func runtimeName(_ identifier: String) -> String {
        let parts = (identifier.components(separatedBy: "SimRuntime.").last ?? identifier).split(separator: "-").map(String.init)
        guard let platform = parts.first else { return identifier }
        let version = parts.dropFirst().prefix { Int($0) != nil }
        return version.isEmpty ? platform : "\(platform) \(version.joined(separator: "."))"
    }
}
