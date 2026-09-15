import Foundation

/// Net effect of one or more `history.list` pages (architecture §4.3 reducer rules). Pure value.
public struct HistoryChanges: Sendable, Equatable {
    public var added: [String: GmailMessageRef]
    public var deleted: Set<String>
    public var labelOps: [String: [LabelDelta]]
    public var finalLabels: [String: Set<String>]
    public var touchedThreads: Set<String>
    public var recordCount: Int
    public var newHistoryId: UInt64?

    public init(
        added: [String: GmailMessageRef] = [:], deleted: Set<String> = [], labelOps: [String: [LabelDelta]] = [:],
        finalLabels: [String: Set<String>] = [:], touchedThreads: Set<String> = [], recordCount: Int = 0,
        newHistoryId: UInt64? = nil
    ) {
        self.added = added
        self.deleted = deleted
        self.labelOps = labelOps
        self.finalLabels = finalLabels
        self.touchedThreads = touchedThreads
        self.recordCount = recordCount
        self.newHistoryId = newHistoryId
    }

    /// `added.keys ∪ labelOps.keys ∪ deleted` — the ids whose local existence the delta must look up.
    public var mentionedIds: Set<String> {
        Set(added.keys).union(labelOps.keys).union(deleted)
    }
}

public enum HistoryReducer {
    /// Reduces pages in order (records inside a page in array order). Never throws.
    public static func reduce(_ pages: [GmailListHistoryResponse]) -> HistoryChanges {
        var c = HistoryChanges()
        func touch(_ threadId: String?) { if let threadId { c.touchedThreads.insert(threadId) } }

        for page in pages {
            for record in page.history ?? [] {
                c.recordCount += 1
                for ch in record.messagesAdded ?? [] {
                    let id = ch.message.id
                    c.added[id] = ch.message
                    c.deleted.remove(id)
                    if let l = ch.message.labelIds { c.finalLabels[id] = Set(l) }
                    touch(ch.message.threadId)
                }
                for ch in record.messagesDeleted ?? [] {
                    let id = ch.message.id
                    c.deleted.insert(id)
                    c.added.removeValue(forKey: id)
                    c.labelOps.removeValue(forKey: id)
                    c.finalLabels.removeValue(forKey: id)
                    touch(ch.message.threadId)
                }
                for ch in record.labelsAdded ?? [] {
                    let id = ch.message.id
                    c.labelOps[id, default: []].append(LabelDelta(add: Set(ch.labelIds ?? []), remove: []))
                    if let l = ch.message.labelIds { c.finalLabels[id] = Set(l) }
                    touch(ch.message.threadId)
                }
                for ch in record.labelsRemoved ?? [] {
                    let id = ch.message.id
                    c.labelOps[id, default: []].append(LabelDelta(add: [], remove: Set(ch.labelIds ?? [])))
                    if let l = ch.message.labelIds { c.finalLabels[id] = Set(l) }
                    touch(ch.message.threadId)
                }
            }
        }
        for id in c.deleted {
            c.labelOps.removeValue(forKey: id)
            c.finalLabels.removeValue(forKey: id)
        }
        c.newHistoryId = pages.last?.historyId?.value
        return c
    }
}
