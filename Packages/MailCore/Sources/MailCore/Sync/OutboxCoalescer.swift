import Foundation

public enum OutboxCoalescer {
    /// Coalesces `new` onto `existing` so that opposite intents cancel:
    ///   add    = (existing.add − new.remove) ∪ (new.add − existing.remove)
    ///   remove = (existing.remove − new.add) ∪ (new.remove − existing.add)
    /// Read-then-unread (remove UNREAD then add UNREAD) collapses to an empty delta — this is what makes
    /// `OutboxRepository.enqueueModify` delete the row (acceptance §9.5 "Read→unread produces zero outbox rows").
    ///
    /// NOTE: the spec §3.2/§4.2 wrote the non-cancelling form `add = (existing.add − new.remove) ∪ new.add`, which
    /// leaves `{add: UNREAD}` for the inverse case and so contradicts both `testInverseCancels` and acceptance §9.5.
    /// The cancelling form here is the one those two require; recorded in the module-06 implementation notes.
    public static func merge(existing: LabelDelta, new: LabelDelta) -> LabelDelta {
        LabelDelta(
            add: existing.add.subtracting(new.remove).union(new.add.subtracting(existing.remove)),
            remove: existing.remove.subtracting(new.add).union(new.remove.subtracting(existing.add))
        )
    }
}
