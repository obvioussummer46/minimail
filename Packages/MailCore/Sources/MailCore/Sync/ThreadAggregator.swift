import Foundation

/// One VISIBLE (isHidden = 0) message of a thread, as read from the `message` table.
public struct AggregateInput: Sendable, Equatable {
    public var id: String
    public var internalDate: Int64
    public var subject: String
    public var snippet: String
    public var fromName: String?
    public var fromAddr: String
    public var isFromMe: Bool
    public var isUnread: Bool
    public var inInbox: Bool
    public var hasAttachments: Bool
    public var bodyState: Int
    public var labelIds: Set<String>

    public init(
        id: String, internalDate: Int64, subject: String, snippet: String, fromName: String?, fromAddr: String,
        isFromMe: Bool, isUnread: Bool, inInbox: Bool, hasAttachments: Bool, bodyState: Int, labelIds: Set<String>
    ) {
        self.id = id
        self.internalDate = internalDate
        self.subject = subject
        self.snippet = snippet
        self.fromName = fromName
        self.fromAddr = fromAddr
        self.isFromMe = isFromMe
        self.isUnread = isUnread
        self.inInbox = inInbox
        self.hasAttachments = hasAttachments
        self.bodyState = bodyState
        self.labelIds = labelIds
    }
}

/// The derived `thread` row (+ the `thread_label` set) for one thread.
public struct ThreadAggregate: Sendable, Equatable {
    public var subject: String
    public var snippet: String
    public var lastDate: Int64
    public var lastInboxDate: Int64?
    public var messageCount: Int
    public var unreadCount: Int
    public var inInbox: Bool
    public var hasAttachments: Bool
    public var participants: String
    public var userLabelIds: [String]
    public var allLabelIds: Set<String>
    public var bodiesMissing: Int

    public init(
        subject: String, snippet: String, lastDate: Int64, lastInboxDate: Int64?, messageCount: Int,
        unreadCount: Int, inInbox: Bool, hasAttachments: Bool, participants: String, userLabelIds: [String],
        allLabelIds: Set<String>, bodiesMissing: Int
    ) {
        self.subject = subject
        self.snippet = snippet
        self.lastDate = lastDate
        self.lastInboxDate = lastInboxDate
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.inInbox = inInbox
        self.hasAttachments = hasAttachments
        self.participants = participants
        self.userLabelIds = userLabelIds
        self.allLabelIds = allLabelIds
        self.bodiesMissing = bodiesMissing
    }
}

public enum ThreadAggregator {
    public static let maxParticipants = 3

    /// `nil` when `messages` is empty. Input order is irrelevant (sorted internally by (internalDate, id)).
    /// A sender counts as "Me" when `isFromMe` or `selfAddresses.contains(fromAddr.lowercased())`.
    public static func aggregate(_ messages: [AggregateInput], selfAddresses: Set<String>) -> ThreadAggregate? {
        guard !messages.isEmpty else { return nil }
        let sorted = messages.sorted { ($0.internalDate, $0.id) < ($1.internalDate, $1.id) }
        func isMe(_ m: AggregateInput) -> Bool {
            m.isFromMe || selfAddresses.contains(m.fromAddr.lowercased())
        }

        let subject = SubjectPrefix.stripForDisplay(sorted.first!.subject)
        let snippet = sorted.last!.snippet
        let lastDate = sorted.last!.internalDate
        let lastInboxDate = sorted.filter { $0.inInbox && !isMe($0) }.map(\.internalDate).max()

        var participants: [String] = []
        var seenKeys = Set<String>()
        for m in sorted {
            let me = isMe(m)
            let key = me ? "me" : m.fromAddr.lowercased()
            guard seenKeys.insert(key).inserted else { continue }
            participants.append(me ? "Me" : firstName(name: m.fromName, addr: m.fromAddr))
        }
        let participantsText: String
        if participants.count > maxParticipants {
            participantsText = participants.prefix(maxParticipants).joined(separator: ", ") + "\u{2026}"
        } else {
            participantsText = participants.joined(separator: ", ")
        }

        let allLabelIds = sorted.reduce(into: Set<String>()) { $0.formUnion($1.labelIds) }

        return ThreadAggregate(
            subject: subject,
            snippet: snippet,
            lastDate: lastDate,
            lastInboxDate: lastInboxDate,
            messageCount: sorted.count,
            unreadCount: sorted.filter(\.isUnread).count,
            inInbox: sorted.contains(where: \.inInbox),
            hasAttachments: sorted.contains(where: \.hasAttachments),
            participants: participantsText,
            userLabelIds: LabelAlgebra.userVisible(allLabelIds),
            allLabelIds: allLabelIds,
            bodiesMissing: sorted.filter { $0.bodyState == 0 }.count
        )
    }

    /// First-name rule: `"Alice Müller"` → `"Alice"`, `"Müller, Bob"` → `"Bob"`, `nil`/blank → local part of `addr`.
    public static func firstName(name: String?, addr: String) -> String {
        var s = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s.removeFirst()
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let comma = s.firstIndex(of: ",") {
            s = String(s[s.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !s.isEmpty {
            let run = s.prefix { !$0.isWhitespace }
            return String(run)
        }
        let local = addr.split(separator: "@", maxSplits: 1).first.map(String.init) ?? addr
        return local.isEmpty ? "?" : local
    }
}
