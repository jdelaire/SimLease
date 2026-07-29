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
    @Published public private(set) var selectedTargetIDs = Set<String>()

    private let provider: any MenuCleanupProviding

    public init(provider: any MenuCleanupProviding) {
        self.provider = provider
    }

    public func load() async {
        state = .loading
        error = nil
        confirmationText = ""
        selectedTargetIDs = []
        do {
            let review = try await provider.plan()
            selectedTargetIDs =
                review.plan?.defaultSelectedTargetIDs ?? []
            state = .review(review)
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
            state = .result(
                try await provider.apply(
                    id: plan.id,
                    selectedTargetIDs: selectedTargetIDs
                )
            )
        } catch {
            self.error = error.localizedDescription
            state = .review(review)
        }
    }

    public var canApply: Bool {
        guard case .review(let review) = state,
              let plan = review.plan,
              !selectedTargetIDs.isEmpty,
              selectedTargetIDs.isSubset(
                of: Set(plan.targets.map(\.identifier))
              )
        else {
            return false
        }
        return confirmationText == plan.id
    }

    public func setSelected(_ selected: Bool, targetID: String) {
        guard case .review(let review) = state,
              review.plan?.targets.contains(where: {
                  $0.identifier == targetID
              }) == true
        else {
            return
        }
        if selected {
            selectedTargetIDs.insert(targetID)
        } else {
            selectedTargetIDs.remove(targetID)
        }
    }

    public var selectedDeleteBytes: Int64 {
        selectedTargets
            .filter { $0.action == .deletePermanently }
            .reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
    }

    public var selectedTrashCount: Int {
        selectedTargets.count { $0.action == .moveToTrash }
    }

    public var primaryActionTitle: String {
        let deleteBytes = selectedDeleteBytes
        let trashCount = selectedTrashCount
        switch (deleteBytes > 0, trashCount > 0) {
        case (true, true):
            return "Delete \(bytes(deleteBytes)) + Trash \(trashCount) \(itemWord(trashCount))"
        case (true, false):
            return "Delete \(bytes(deleteBytes))"
        case (false, true):
            return "Move \(trashCount) \(itemWord(trashCount)) to Trash"
        case (false, false):
            return "Select Items"
        }
    }

    private var selectedTargets: [CleanupTarget] {
        guard case .review(let review) = state,
              let plan = review.plan
        else {
            return []
        }
        return plan.targets.filter {
            selectedTargetIDs.contains($0.identifier)
        }
    }

    private func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }

    private func itemWord(_ count: Int) -> String {
        count == 1 ? "Item" : "Items"
    }
}
