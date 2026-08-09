import Foundation

enum ParsedCommand: Equatable {
    case version
    case update
    case status(json: Bool)
    case name(String)
    case hold(title: String, project: String)
    case cleanPlan(json: Bool)
    case cleanApply(id: String, targetIDs: [String], json: Bool)
    case laneAcquire(project: String, deviceType: String, runtime: String, json: Bool)
    case laneStatus(json: Bool)
    case laneConfig(maxActive: Int?, json: Bool)
    case laneRelease(json: Bool)
    case laneRecoverPlan(laneID: String, json: Bool)
    case laneRecoverApply(planID: String, laneID: String, json: Bool)
    case laneDisposePlan(udid: String, json: Bool)
    case laneDisposeApply(planID: String, udid: String, json: Bool)
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
        case "status":
            guard arguments.count <= 3,
                  arguments.count == 2 || arguments[2] == "--json"
            else {
                throw CommandParserError.usage
            }
            return .status(json: arguments.count == 3)
        case "name":
            guard arguments.count == 3 else {
                throw CommandParserError.usage
            }
            return .name(arguments[2])
        case "hold":
            var title: String?
            var project: String?
            var index = 2
            while index < arguments.count {
                guard index + 1 < arguments.count else {
                    throw CommandParserError.usage
                }
                switch arguments[index] {
                case "--title":
                    title = arguments[index + 1]
                case "--project":
                    project = arguments[index + 1]
                default:
                    throw CommandParserError.usage
                }
                index += 2
            }
            guard let title, let project else {
                throw CommandParserError.usage
            }
            return .hold(title: title, project: project)
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
        case "lane":
            return try parseLane(Array(arguments.dropFirst(2)))
        default:
            throw CommandParserError.usage
        }
    }

    private static func parseLane(_ arguments: [String]) throws -> ParsedCommand {
        guard let subcommand = arguments.first else {
            throw CommandParserError.usage
        }
        switch subcommand {
        case "acquire":
            var project: String?
            var deviceType: String?
            var runtime: String?
            var json = false
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--project":
                    project = try parseUniqueValue(arguments, index: &index, current: project)
                case "--device-type":
                    deviceType = try parseUniqueValue(arguments, index: &index, current: deviceType)
                case "--runtime":
                    runtime = try parseUniqueValue(arguments, index: &index, current: runtime)
                case "--json":
                    guard !json else { throw CommandParserError.usage }
                    json = true
                    index += 1
                default:
                    throw CommandParserError.usage
                }
            }
            guard let project, let deviceType, let runtime else {
                throw CommandParserError.usage
            }
            return .laneAcquire(
                project: project,
                deviceType: deviceType,
                runtime: runtime,
                json: json
            )
        case "status":
            let json = try parseOptionalJSON(Array(arguments.dropFirst()))
            return .laneStatus(json: json)
        case "config":
            var maxActive: Int?
            var json = false
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--max-active":
                    guard maxActive == nil,
                          index + 1 < arguments.count,
                          let value = Int(arguments[index + 1]),
                          value > 0 else {
                        throw CommandParserError.usage
                    }
                    maxActive = value
                    index += 2
                case "--json":
                    guard !json else { throw CommandParserError.usage }
                    json = true
                    index += 1
                default:
                    throw CommandParserError.usage
                }
            }
            return .laneConfig(maxActive: maxActive, json: json)
        case "release":
            let json = try parseOptionalJSON(Array(arguments.dropFirst()))
            return .laneRelease(json: json)
        case "recover":
            return try parseLaneLifecycle(
                Array(arguments.dropFirst()),
                targetFlag: "--lane",
                makePlan: { .laneRecoverPlan(laneID: $0, json: $1) },
                makeApply: {
                    .laneRecoverApply(planID: $0, laneID: $1, json: $2)
                }
            )
        case "dispose":
            return try parseLaneLifecycle(
                Array(arguments.dropFirst()),
                targetFlag: "--target",
                makePlan: { .laneDisposePlan(udid: $0, json: $1) },
                makeApply: {
                    .laneDisposeApply(planID: $0, udid: $1, json: $2)
                }
            )
        default:
            throw CommandParserError.usage
        }
    }

    private static func parseLaneLifecycle(
        _ arguments: [String],
        targetFlag: String,
        makePlan: (String, Bool) -> ParsedCommand,
        makeApply: (String, String, Bool) -> ParsedCommand
    ) throws -> ParsedCommand {
        guard let action = arguments.first else {
            throw CommandParserError.usage
        }
        switch action {
        case "plan":
            guard arguments.count == 2 || arguments.count == 3,
                  !arguments[1].isEmpty,
                  !arguments[1].hasPrefix("--") else {
                throw CommandParserError.usage
            }
            let json = try parseOptionalJSON(Array(arguments.dropFirst(2)))
            return makePlan(arguments[1], json)
        case "apply":
            guard arguments.count >= 4,
                  validPlanID(arguments[1]) else {
                throw CommandParserError.usage
            }
            var target: String?
            var json = false
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case targetFlag:
                    target = try parseUniqueValue(
                        arguments,
                        index: &index,
                        current: target
                    )
                case "--json":
                    guard !json else { throw CommandParserError.usage }
                    json = true
                    index += 1
                default:
                    throw CommandParserError.usage
                }
            }
            guard let target else { throw CommandParserError.usage }
            return makeApply(arguments[1], target, json)
        default:
            throw CommandParserError.usage
        }
    }

    private static func parseUniqueValue(
        _ arguments: [String],
        index: inout Int,
        current: String?
    ) throws -> String {
        guard current == nil,
              index + 1 < arguments.count,
              !arguments[index + 1].isEmpty,
              !arguments[index + 1].hasPrefix("--") else {
            throw CommandParserError.usage
        }
        let value = arguments[index + 1]
        index += 2
        return value
    }

    private static func parseOptionalJSON(_ arguments: [String]) throws -> Bool {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CommandParserError.usage
        }
        return !arguments.isEmpty
    }

    private static func validPlanID(_ id: String) -> Bool {
        id.utf8.count == 6 && id.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0)
        }
    }
}
