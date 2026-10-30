import Foundation

enum ParsedCommand: Equatable {
    case version
    case update
    case run(deviceIDs: [String], keepRunning: Bool, keepWarm: Bool = false, command: [String], title: String? = nil)
    case recover
    case deviceCreate(name: String, deviceType: String, runtime: String)
    case deviceRepair(String, settled: Bool, acknowledgeCrashes: Bool)
    case deviceRecover
    case deviceShutdown([String])
    case deviceMaintain
    case deviceReap
    case deviceAcknowledge(String)
    case deviceSlimList(json: Bool)
    case deviceSlim(id: String, keep: [String], settled: Bool)
    case deviceUnslim(id: String, settled: Bool)
    case config(maxLanes: Int?)
    case history(hours: Int)
    case sessionBegin(title: String, project: String, deviceIDs: [String], clientPIDs: [Int32] = [])
    case sessionFinish(String)
    case nativeWait(String)
    case doctor(json: Bool)
    case status(json: Bool, audit: Bool = false, devices: Bool = false)
    case measure(deviceID: String, json: Bool, limit: Int)
    case name(String)
    case hold(title: String, project: String, deviceIDs: [String] = [], keepRunning: Bool = false)
    case cleanPlan(json: Bool)
    case cleanApply(id: String, targetIDs: [String], json: Bool)
    case shim(arguments: [String])
}

enum CommandParserError: Error, Equatable {
    case usage
}

enum CommandParser {
    static func parse(_ arguments: [String]) throws -> ParsedCommand {
        guard let executable = arguments.first else {
            throw CommandParserError.usage
        }
        guard URL(fileURLWithPath: executable).lastPathComponent == "simlease" else {
            return .shim(arguments: arguments)
        }
        guard arguments.count >= 2 else {
            throw CommandParserError.usage
        }

        switch arguments[1] {
        case "device":
            return try parseDevice(Array(arguments.dropFirst(2)))
        case "session":
            guard arguments.indices.contains(2) else { throw CommandParserError.usage }
            if arguments[2] == "finish" {
                guard arguments.count == 5, let id = UUID(uuidString: arguments[3]), arguments[4] == "--settled" else { throw CommandParserError.usage }
                return .sessionFinish(id.uuidString)
            }
            guard arguments[2] == "begin" else { throw CommandParserError.usage }
            var title: String?
            var project: String?
            var ids = [String]()
            var clients = [Int32]()
            var index = 3
            while index < arguments.count {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty else { throw CommandParserError.usage }
                switch arguments[index] {
                case "--title":
                    guard title == nil else { throw CommandParserError.usage }
                    title = arguments[index + 1]
                case "--project":
                    guard project == nil else { throw CommandParserError.usage }
                    project = arguments[index + 1]
                case "--device":
                    guard let id = UUID(uuidString: arguments[index + 1]) else { throw CommandParserError.usage }
                    ids.append(id.uuidString)
                case "--client-pid":
                    guard let pid = Int32(arguments[index + 1]), pid > 1 else { throw CommandParserError.usage }
                    clients.append(pid)
                default: throw CommandParserError.usage
                }
                index += 2
            }
            guard let title, let project, !ids.isEmpty else { throw CommandParserError.usage }
            return .sessionBegin(title: title, project: project, deviceIDs: ids, clientPIDs: clients)
        case "__native_wait":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[2]) else { throw CommandParserError.usage }
            return .nativeWait(id.uuidString)
        case "recover":
            guard arguments.count == 2 else { throw CommandParserError.usage }
            return .recover
        case "run":
            var ids = [String]()
            var keepRunning = false
            var keepWarm = false
            var title: String?
            var index = 2
            while index < arguments.count, arguments[index] != "--" {
                switch arguments[index] {
                case "--title":
                    guard title == nil, arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty else { throw CommandParserError.usage }
                    title = arguments[index + 1]
                    index += 2
                case "--device":
                    guard arguments.indices.contains(index + 1),
                          let id = UUID(uuidString: arguments[index + 1])
                    else { throw CommandParserError.usage }
                    ids.append(id.uuidString)
                    index += 2
                case "--keep-running":
                    guard !keepRunning, !keepWarm else { throw CommandParserError.usage }
                    keepRunning = true
                    index += 1
                case "--keep-warm":
                    guard !keepWarm, !keepRunning else { throw CommandParserError.usage }
                    keepWarm = true
                    index += 1
                default:
                    throw CommandParserError.usage
                }
            }
            guard arguments.indices.contains(index), arguments[index] == "--",
                  arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty
            else { throw CommandParserError.usage }
            guard !keepWarm || !ids.isEmpty else { throw CommandParserError.usage }
            return .run(deviceIDs: ids, keepRunning: keepRunning, keepWarm: keepWarm, command: Array(arguments.dropFirst(index + 1)), title: title)
        case "--version":
            guard arguments.count == 2 else {
                throw CommandParserError.usage
            }
            return .version
        case "history":
            let flags = Array(arguments.dropFirst(2))
            var hours = 24
            var index = 0
            while index < flags.count {
                if flags[index] == "--json" { index += 1; continue }
                guard flags[index] == "--hours", flags.indices.contains(index + 1), let value = Int(flags[index + 1]), (1...168).contains(value) else { throw CommandParserError.usage }
                hours = value
                index += 2
            }
            return .history(hours: hours)
        case "config":
            let flags = Array(arguments.dropFirst(2))
            if flags.isEmpty { return .config(maxLanes: nil) }
            guard flags.count == 2, flags[0] == "--max-lanes", let value = Int(flags[1]), (1...3).contains(value) else {
                throw CommandParserError.usage
            }
            return .config(maxLanes: value)
        case "update":
            guard arguments.count == 2 else {
                throw CommandParserError.usage
            }
            return .update
        case "status":
            let flags = Array(arguments.dropFirst(2))
            guard Set(flags).count == flags.count, flags.allSatisfy({ ["--json", "--audit", "--devices"].contains($0) }) else {
                throw CommandParserError.usage
            }
            return .status(json: flags.contains("--json"), audit: flags.contains("--audit"), devices: flags.contains("--devices"))
        case "measure":
            var id: String?
            var json = false
            var limit: Int?
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case "--json":
                    guard !json else { throw CommandParserError.usage }
                    json = true
                    index += 1
                case "--device":
                    guard id == nil, arguments.indices.contains(index + 1), let value = UUID(uuidString: arguments[index + 1]) else { throw CommandParserError.usage }
                    id = value.uuidString
                    index += 2
                case "--limit":
                    guard limit == nil, arguments.indices.contains(index + 1), let value = Int(arguments[index + 1]), value > 0 else { throw CommandParserError.usage }
                    limit = value
                    index += 2
                default:
                    throw CommandParserError.usage
                }
            }
            guard let id else { throw CommandParserError.usage }
            return .measure(deviceID: id, json: json, limit: limit ?? 15)
        case "doctor":
            guard arguments.count <= 3,
                  arguments.count == 2 || arguments[2] == "--json"
            else {
                throw CommandParserError.usage
            }
            return .doctor(json: arguments.count == 3)
        case "name":
            guard arguments.count == 3 else {
                throw CommandParserError.usage
            }
            return .name(arguments[2])
        case "hold":
            var title: String?
            var project: String?
            var ids = [String]()
            var keepRunning = false
            var index = 2
            while index < arguments.count {
                if arguments[index] == "--keep-running" {
                    guard !keepRunning else { throw CommandParserError.usage }
                    keepRunning = true
                    index += 1
                    continue
                }
                guard index + 1 < arguments.count else { throw CommandParserError.usage }
                switch arguments[index] {
                case "--title":
                    title = arguments[index + 1]
                case "--project":
                    project = arguments[index + 1]
                case "--device":
                    guard let id = UUID(uuidString: arguments[index + 1]) else { throw CommandParserError.usage }
                    ids.append(id.uuidString)
                default:
                    throw CommandParserError.usage
                }
                index += 2
            }
            guard let title, let project else {
                throw CommandParserError.usage
            }
            return .hold(title: title, project: project, deviceIDs: ids, keepRunning: keepRunning)
        case "clean":
            guard arguments.count >= 3 else {
                throw CommandParserError.usage
            }
            switch arguments[2] {
            case "plan":
                guard arguments.count == 3
                        || (arguments.count == 4 && arguments[3] == "--json")
                else {
                    throw CommandParserError.usage
                }
                return .cleanPlan(json: arguments.count == 4)
            case "apply":
                guard arguments.count >= 6,
                      validPlanID(arguments[3]) else {
                    throw CommandParserError.usage
                }
                var targetIDs = [String]()
                var json = false
                var index = 4
                while index < arguments.count {
                    switch arguments[index] {
                    case "--target":
                        guard index + 1 < arguments.count,
                              !arguments[index + 1].isEmpty,
                              !arguments[index + 1].hasPrefix("--")
                        else {
                            throw CommandParserError.usage
                        }
                        targetIDs.append(arguments[index + 1])
                        index += 2
                    case "--json":
                        guard !json else {
                            throw CommandParserError.usage
                        }
                        json = true
                        index += 1
                    default:
                        throw CommandParserError.usage
                    }
                }
                guard !targetIDs.isEmpty else {
                    throw CommandParserError.usage
                }
                return .cleanApply(
                    id: arguments[3],
                    targetIDs: targetIDs,
                    json: json
                )
            default:
                throw CommandParserError.usage
            }
        default:
            throw CommandParserError.usage
        }
    }

    private static func validPlanID(_ id: String) -> Bool {
        id.utf8.count == 6 && id.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0)
        }
    }

    private static func parseDevice(_ arguments: [String]) throws -> ParsedCommand {
        guard let action = arguments.first else { throw CommandParserError.usage }
        if action == "maintain" {
            guard arguments.count == 1 else { throw CommandParserError.usage }
            return .deviceMaintain
        }
        if action == "reap" {
            guard arguments.count == 1 else { throw CommandParserError.usage }
            return .deviceReap
        }
        if action == "slim" || action == "unslim" {
            var id: String?
            var keep: [String]?
            var flags = Set<String>()
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                if ["--list", "--settled", "--json"].contains(key) {
                    guard flags.insert(key).inserted else { throw CommandParserError.usage }
                    index += 1
                    continue
                }
                guard arguments.indices.contains(index + 1) else { throw CommandParserError.usage }
                let value = arguments[index + 1]
                switch key {
                case "--device":
                    guard id == nil, let uuid = UUID(uuidString: value) else { throw CommandParserError.usage }
                    id = uuid.uuidString
                case "--keep" where action == "slim":
                    let items = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard keep == nil, !items.contains(where: \.isEmpty), Set(items).count == items.count else { throw CommandParserError.usage }
                    keep = items
                default:
                    throw CommandParserError.usage
                }
                index += 2
            }
            if flags.contains("--list") {
                guard action == "slim", id == nil, keep == nil, !flags.contains("--settled") else { throw CommandParserError.usage }
                return .deviceSlimList(json: flags.contains("--json"))
            }
            guard let id else { throw CommandParserError.usage }
            return action == "slim" ? .deviceSlim(id: id, keep: keep ?? [], settled: flags.contains("--settled")) : .deviceUnslim(id: id, settled: flags.contains("--settled"))
        }
        if action == "shutdown" {
            var ids = [String]()
            var index = 1
            while index < arguments.count {
                guard arguments[index] == "--device", arguments.indices.contains(index + 1),
                      let id = UUID(uuidString: arguments[index + 1])?.uuidString, !ids.contains(id) else { throw CommandParserError.usage }
                ids.append(id)
                index += 2
            }
            guard !ids.isEmpty else { throw CommandParserError.usage }
            return .deviceShutdown(ids)
        }
        var values = [String: String]()
        var flags = Set<String>()
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            if ["--disposable", "--settled", "--acknowledge-crashes", "--json"].contains(key) {
                guard flags.insert(key).inserted else { throw CommandParserError.usage }
                index += 1
            } else {
                guard ["--name", "--type", "--runtime", "--device"].contains(key), values[key] == nil,
                      arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("--") else { throw CommandParserError.usage }
                values[key] = arguments[index + 1]
                index += 2
            }
        }
        switch action {
        case "create":
            guard values.count == 3, let name = values["--name"], let type = values["--type"], let runtime = values["--runtime"],
                  type.hasPrefix("com.apple.CoreSimulator.SimDeviceType."), runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime."),
                  flags.contains("--disposable"), flags.isSubset(of: ["--disposable", "--json"]) else { throw CommandParserError.usage }
            return .deviceCreate(name: name, deviceType: type, runtime: runtime)
        case "acknowledge":
            guard values.count == 1, flags.isEmpty || flags == ["--json"], let value = values["--device"], let id = UUID(uuidString: value) else { throw CommandParserError.usage }
            return .deviceAcknowledge(id.uuidString)
        case "repair":
            guard values.count == 1, let value = values["--device"], let id = UUID(uuidString: value),
                  flags.isSubset(of: ["--settled", "--acknowledge-crashes", "--json"]) else { throw CommandParserError.usage }
            return .deviceRepair(id.uuidString, settled: flags.contains("--settled"), acknowledgeCrashes: flags.contains("--acknowledge-crashes"))
        case "recover":
            guard values.isEmpty, flags.contains("--settled"), flags.isSubset(of: ["--settled", "--json"]) else { throw CommandParserError.usage }
            return .deviceRecover
        default: throw CommandParserError.usage
        }
    }
}
