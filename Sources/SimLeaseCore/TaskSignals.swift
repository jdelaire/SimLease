import Darwin
import Dispatch
import Foundation

public final class TaskSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int32?
    private var sources: [DispatchSourceSignal] = []
    private var previous: [(Int32, sig_t?)] = []

    public init() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            previous.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                self?.cancel(signal: number)
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
        previous.forEach { _ = signal($0.0, $0.1) }
    }

    public var current: Int32? { lock.withLock { received } }

    public func cancel(signal: Int32 = SIGTERM) {
        guard [SIGINT, SIGTERM, SIGHUP].contains(signal) else { return }
        lock.withLock { if received == nil { received = signal } }
    }
}
