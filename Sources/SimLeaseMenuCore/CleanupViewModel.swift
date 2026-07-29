import Combine
import Foundation
import SimLeaseCore

public enum CleanupViewState: Equatable, Sendable {
    case idle
    case loading
    case review(CleanupReview)
    case applying(CleanupReview)
    case result(CleanupResult)
    case error(String)
}

@MainActor
public final class CleanupViewModel: ObservableObject {
    @Published public private(set) var state: CleanupViewState = .idle
    @Published public var confirmationText = ""
    @Published public private(set) var error: String?

    private let provider: any MenuCleanupProviding

    public init(provider: any MenuCleanupProviding) {
        self.provider = provider
    }

    public func load() async {
        state = .loading
        error = nil
        confirmationText = ""
        do {
            state = .review(try await provider.plan())
        } catch {
            let message = error.localizedDescription
            self.error = message
            state = .error(message)
        }
    }

    public func apply() async {
        guard case .review(let review) = state,
              let plan = review.plan,
              canApply
        else {
            return
        }
        state = .applying(review)
        error = nil
        do {
            state = .result(try await provider.apply(id: plan.id))
        } catch {
            self.error = error.localizedDescription
            state = .review(review)
        }
    }

    public var canApply: Bool {
        guard case .review(let review) = state,
              let plan = review.plan,
              !plan.devices.isEmpty || !plan.runtimes.isEmpty
        else {
            return false
        }
        return confirmationText == plan.id
    }
}
