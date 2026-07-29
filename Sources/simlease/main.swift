import Foundation
import SimLeaseCLI
import Darwin

let environment = ProcessInfo.processInfo.environment
exit(SimLeaseCLI.run(
    arguments: CommandLine.arguments,
    environment: environment,
    configuration: .production(environment: environment)
))
