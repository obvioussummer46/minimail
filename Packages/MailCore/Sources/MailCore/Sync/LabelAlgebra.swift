import Foundation

/// A label change: `add` wins over `remove` when both contain an id (see `applied(to:)`). `Codable` form:
/// `{"add":["A","B"],"remove":["C"]}` with each array sorted ascending (custom `encode(to:)`), so JSON is stable.
public struct LabelDelta: Codable, Sendable, Equatable {
    public var add: Set<String>
    public var remove: Set<String>

    public init(add: Set<String> = [], remove: Set<String> = []) {
        self.add = add
        self.remove = remove
    }

    public var isEmpty: Bool { add.isEmpty && remove.isEmpty }

    /// `(labels − remove) ∪ add`.
    public func applied(to labels: Set<String>) -> Set<String> {
        labels.subtracting(remove).union(add)
    }

    public var sortedAdd: [String] { add.sorted() }
    public var sortedRemove: [String] { remove.sorted() }

    private enum CodingKeys: String, CodingKey { case add, remove }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(add.sorted(), forKey: .add)
        try container.encode(remove.sorted(), forKey: .remove)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        add = Set(try container.decode([String].self, forKey: .add))
        remove = Set(try container.decode([String].self, forKey: .remove))
    }
}

/// Flags every message row carries, derived from its effective label set.
public struct DerivedFlags: Sendable, Equatable {
    public var isUnread: Bool
    public var inInbox: Bool
    public var isHidden: Bool

    public init(isUnread: Bool, inInbox: Bool, isHidden: Bool) {
        self.isUnread = isUnread
        self.inInbox = inInbox
        self.isHidden = isHidden
    }
}

public enum LabelAlgebra {
    public static let inbox = "INBOX"
    public static let unread = "UNREAD"
    public static let sent = "SENT"
    public static let starred = "STARRED"
    public static let important = "IMPORTANT"
    /// TRASH ∨ SPAM ∨ DRAFT ∨ CHAT.
    public static let hiddenIds: Set<String> = ["TRASH", "SPAM", "DRAFT", "CHAT"]
    /// Ids never shown as chips (+ every `CATEGORY_*`, see `isSystem`).
    public static let systemIds: Set<String> = [
        "INBOX", "UNREAD", "SENT", "DRAFT", "CHAT", "SPAM", "TRASH", "STARRED", "IMPORTANT",
    ]

    public static func isSystem(_ id: String) -> Bool {
        systemIds.contains(id) || id.hasPrefix("CATEGORY_")
    }

    /// Folds `applied(to:)` over `pending` in array order: E = pₙ(…p₁(S)).
    public static func effective(server: Set<String>, pending: [LabelDelta]) -> Set<String> {
        pending.reduce(server) { $1.applied(to: $0) }
    }

    public static func flags(_ labels: Set<String>) -> DerivedFlags {
        DerivedFlags(
            isUnread: labels.contains(unread),
            inInbox: labels.contains(inbox),
            isHidden: !labels.isDisjoint(with: hiddenIds)
        )
    }

    /// `["A","B"]` — ids sorted ascending, JSON-escaped, no whitespace, `/` not escaped. `[]` for the empty set.
    public static func sortedJSON(_ labels: Set<String>) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(labels.sorted()) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Inverse of `sortedJSON`; any JSON array of strings is accepted; malformed input → `[]`.
    public static func parseJSON(_ json: String) -> Set<String> {
        guard let array = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return Set(array)
    }

    /// Sorted ascending; excludes every id for which `isSystem` is true.
    public static func userVisible(_ labels: Set<String>) -> [String] {
        labels.filter { !isSystem($0) }.sorted()
    }
}
