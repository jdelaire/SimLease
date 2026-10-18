import Foundation

enum ParsedCommand: Equatable {
    case version
    case update
    case run(deviceIDs: [String], keepRunning: Bool, command: [String])
    case recover
    case doctor(json: Bool)
    case status(json: Bool)
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
        case "recover":
            guard arguments.count == 2 else { throw CommandParserError.usage }
            return .recover
        case "run":
            var ids = [String]()
            var keepRunning = false
            var index = 2
            while index < arguments.count, arguments[index] != "--" {
                switch arguments[index] {
                case "--device":
                    guard arguments.indices.contains(index + 1),
                          let id = UUID(uuidString: arguments[index + 1])
                    else { throw CommandParserError.usage }
                    ids.append(id.uuidString)
                    index += 2
                case "--keep-running":
                    guard !keepRunning else { throw CommandParserError.usage }
                    keepRunning = true
                    index += 1
                default:
                    throw CommandParserError.usage
                }
            }
            guard arguments.indices.contains(index), arguments[index] == "--",
                  arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty
            else { throw CommandParserError.usage }
            return .run(deviceIDs: ids, keepRunning: keepRunning, command: Array(arguments.dropFirst(index + 1)))
        case "--version":
            guard arguments.count == 2 else {
                throw CommandParserError.usage
            }
            return .version
        case "update":
            guard arguments.count == 2 else {
                throw CommandParserError.usage
            }
            return .update
        case "status", "doctor":
            guard arguments.count <= 3,
                  arguments.count == 2 || arguments[2] == "--json"
            else {
                throw CommandParserError.usage
            }
            return arguments[1] == "doctor" ? .doctor(json: arguments.count == 3) : .status(json: arguments.count == 3)
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
}
