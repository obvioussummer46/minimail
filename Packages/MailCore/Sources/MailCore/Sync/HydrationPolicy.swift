import Foundation

public struct HydrationScope: Sendable, Equatable {
    public var cachedLabelIds: Set<String>
    public var knownThreadIds: Set<String>
    public init(cachedLabelIds: Set<String>, knownThreadIds: Set<String>) {
        self.cachedLabelIds = cachedLabelIds
        self.knownThreadIds = knownThreadIds
    }
}

public enum HydrationPolicy {
    /// True if `ref.labelIds == nil`, or `ref.threadId ∈ knownThreadIds`, or `labelIds ∩ cachedLabelIds ≠ ∅`.
    public static func shouldFetch(ref: GmailMessageRef, scope: HydrationScope) -> Bool {
        guard let labelIds = ref.labelIds else { return true }
        if let threadId = ref.threadId, scope.knownThreadIds.contains(threadId) { return true }
        return !Set(labelIds).isDisjoint(with: scope.cachedLabelIds)
    }
}
