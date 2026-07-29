import Foundation

public protocol LeaseClock: Sendable {
    func wallNow() -> Date
    func monotonicNow() -> ContinuousClock.Instant
    func sleep(for duration: Duration) throws
}

public struct SystemLeaseClock: LeaseClock {
    private let clock = ContinuousClock()

    public init() {}

    public func wallNow() -> Date {
        Date()
    }

    public func monotonicNow() -> ContinuousClock.Instant {
        clock.now
    }

    public func sleep(for duration: Duration) throws {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        if seconds > 0 {
            Thread.sleep(forTimeInterval: seconds)
        }
    }
}

public struct LeaseTiming: Sendable {
    public let timeout: Duration
    public let reportInterval: Duration
    public let pollInterval: Duration

    public init(
        timeout: Duration,
        reportInterval: Duration,
        pollInterval: Duration
    ) {
        self.timeout = timeout
        self.reportInterval = reportInterval
        self.pollInterval = pollInterval
    }

    public static let production = LeaseTiming(
        timeout: .seconds(1_200),
        reportInterval: .seconds(30),
        pollInterval: .milliseconds(200)
    )
}
