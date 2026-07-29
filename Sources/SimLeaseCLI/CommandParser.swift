import Foundation

enum ParsedCommand: Equatable {
    case version
    case update
    case status(json: Bool)
    case name(String)
    case hold(title: String, project: String)
    case cleanPlan(json: Bool)
    case cleanApply(id: String, json: Bool)
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
                guard arguments.count == 4
                        || (arguments.count == 5 && arguments[4] == "--json"),
                      validPlanID(arguments[3])
                else {
                    throw CommandParserError.usage
                }
                return .cleanApply(
                    id: arguments[3],
                    json: arguments.count == 5
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
