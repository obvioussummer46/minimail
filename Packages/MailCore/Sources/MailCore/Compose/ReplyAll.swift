import Foundation

/// Who "I" am: the primary address plus every send-as alias, so reply-all never writes back to me.
public struct SelfIdentity: Sendable, Equatable {
    public var primary: Mailbox
    /// Lowercased addr-specs. Always contains `primary.key`.
    public var allAddresses: Set<String>

    public init(primary: Mailbox, allAddresses: Set<String>) {
        self.primary = primary
        var lowered = Set(allAddresses.map { $0.lowercased() })
        lowered.insert(primary.key)
        self.allAddresses = lowered
    }
}

public struct Recipients: Sendable, Equatable {
    public var to: [Mailbox]
    public var cc: [Mailbox]

    public init(to: [Mailbox], cc: [Mailbox]) {
        self.to = to
        self.cc = cc
    }
}

public enum ReplyAll {

    /// Reply-To wins over From. My own addresses drop out, To wins over Cc for a duplicate, and the first
    /// spelling of a display name wins. Replying to my own message keeps the original recipients, and a reply
    /// that would otherwise have nobody in To falls back to Cc and then to the sender.
    public static func recipients(
        from: Mailbox?,
        replyTo: [Mailbox],
        to: [Mailbox],
        cc: [Mailbox],
        me: SelfIdentity
    ) -> Recipients {
        let isSelfReply = from.map { me.allAddresses.contains($0.key) } ?? false
        let toCandidates: [Mailbox]
        if isSelfReply {
            toCandidates = to
        } else {
            toCandidates = (replyTo.isEmpty ? [from].compactMap { $0 } : replyTo) + to
        }

        var seen = Set<String>()
        func keep(_ mailbox: Mailbox) -> Bool {
            !mailbox.key.isEmpty && !me.allAddresses.contains(mailbox.key)
                && seen.insert(mailbox.key).inserted
        }

        var resolvedTo = toCandidates.filter(keep)
        var resolvedCc = cc.filter(keep)

        if resolvedTo.isEmpty && !resolvedCc.isEmpty {
            resolvedTo = resolvedCc
            resolvedCc = []
        }
        if resolvedTo.isEmpty, let from {
            resolvedTo = [from]
        }
        return Recipients(to: resolvedTo, cc: resolvedCc)
    }
}
