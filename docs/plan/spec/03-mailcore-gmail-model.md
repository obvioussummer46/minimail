# Spec 03 — mailcore-gmail-model: Gmail DTOs, payload parser, batch codec

Module id: `03-mailcore-gmail-model`. Depends on: `01-project-setup` (package layout, `Package.swift`, `Fixtures/` resource directory), `02-mailcore-mime` (encodings and header parsers). Consumed by: 05, 06, 07, 08, 10, 14.
Source of truth: `docs/plan/design/architecture.md` §0 (decisions 1, 5, 6, 8), §1.3, §1.5, §2.1, §2.2 (Gmail section — signatures copied verbatim), §3.3, §4.3–§4.5, §6.1–§6.3, §13.2, §14 (#8, #13, #14), §15 (D4, D6, D17), §16, Appendix A; `docs/plan/design/modules.md` §03; research `[gmail-api]` (Common facts, §1, §3–§6, §9–§15, Gotchas 3, 5, 9, 12–14, 22–23), `[mime-rfc §0, §2.3, §2.4, §5.1–§5.5, §8.3]`.

Conventions: paths are relative to the repo root `/home/user/minimail`. Code blocks marked "verbatim" reproduce architecture §2.2 exactly (whitespace normalised by `make format`). `DEVIATION:` marks a departure from architecture.md with its reason; every deviation is additive. Facts the research files mark UNVERIFIED stay marked UNVERIFIED here. Everything in this module is pure Swift (`Foundation` only), nonisolated, `Sendable`, and runs under `swift test` on Linux and macOS.

---

## 1. Purpose & scope

### 1.1 What this module delivers

Three source files in `Packages/MailCore/Sources/MailCore/Gmail/` plus their tests and the Gmail fixture set:

1. `GmailDTO.swift` — `Codable` mirrors of the Gmail Discovery shapes the app sends and receives (`Profile`, `Label`, `ListLabelsResponse`, `MessagePart`, `MessagePartBody`, `Message`, `Thread`, `ListMessagesResponse`, `History` + change records, `ListHistoryResponse`, `SendAs`, `ListSendAsResponse`, `ModifyThreadRequest`, send request, error envelope), the string-number wrappers `StringUInt64` / `StringInt64` (`[gmail-api gotcha 3]`), the `GmailFormat` enum and the `gmailMetadataHeaders` constant (`[gmail-api gotcha 12]`).
2. `MessageParser.swift` — `GmailMessage` → `ParsedMessage`: decoded headers (`From`/`To`/`Cc`/`Reply-To`/`Subject`/`Message-ID`/`In-Reply-To`/`References`), entity-decoded snippet, `topMimeType`, and — for `format=full` — the MIME tree walk of `[mime-rfc §5.2]` producing `html`/`text` bodies, deferred text parts (`[mime-rfc §5.2 (h)]`, architecture §14 #14) and the attachment list (every fetchable part including inline images), with charset-aware text decoding (`[mime-rfc §5.3]`).
3. `BatchCodec.swift` — `multipart/mixed` request encoder and response parser for `POST https://www.googleapis.com/batch/gmail/v1` (`[gmail-api §12]`): byte-exact encoding, `Content-ID`-based matching, per-part inner status lines.

### 1.2 Explicitly out of scope

- Any HTTP: `URLSession`, request building, `fields=` masks, retries, chunking, `GmailError` mapping (module 05 — it calls `BatchCodec` and decodes DTOs).
- Sanitising HTML, `cid:` rewriting, tracking-pixel removal, dark-mode classification (module 08 — it consumes `ParsedBody.html`).
- Storage mapping: `MessageRecord`, `AttachmentRecord`, `upsertMetadata`, `storeBody`, label algebra, thread aggregation (module 06 — it consumes `ParsedMessage`/`ParsedAttachment`/`GmailLabel`).
- History reduction, hydration policy, fetching deferred text parts (module 07 — it consumes `GmailListHistoryResponse`/`GmailMessageRef`, `MessageParser.parse`, `ParsedBody.deferredTextParts`).
- Building outgoing MIME, base64url *encoding* of `raw` (module 02 `MIMEBuilder`/`Base64URL.encode`; module 03 only uses `Base64URL.decode`).
- `MailHTMLTests`, app tests, `StubURLProtocol`, `FixtureLoader` (module 14). Module 14 may add further Gmail fixtures; it must not change the ones listed in §2/§5.

### 1.3 Consumers and what they take from this module

| Consumer | Symbols used |
|---|---|
| 05 `GmailClient` | every `Gmail*` DTO (decoding responses, encoding `GmailModifyRequest`/`GmailSendRequest`), `GmailErrorEnvelope.primaryReason`, `GmailFormat.rawValue` for `format=`, `gmailMetadataHeaders` for `metadataHeaders=`, `BatchCall`, `BatchPartResponse`, `BatchCodec.encode/boundary(fromContentType:)/decode`, `BatchCodecError`, `StringUInt64`/`StringInt64` |
| 06 Store | `ParsedMessage`, `ParsedHeaders`, `ParsedAttachment` (columns of `message`/`attachment`, §3.3 mapping), `GmailLabel`/`GmailLabelColor` (`LabelRepository.replaceAll/updateCounts`) |
| 07 Sync/Outbox | `GmailListHistoryResponse`, `GmailHistory`, `GmailHistoryMessageChange`, `GmailHistoryLabelChange`, `GmailMessageRef` (`HistoryReducer`, `HydrationPolicy`), `GmailMessage`, `GmailThread`, `MessageParser.parse`, `MessageParser.decodeText(bytes:charset:)` for deferred parts, `ParsedBody.deferredTextParts`, `ParsedAttachment.attachmentId/charset`, `GmailProfile`, `GmailSendAs` |
| 08 Web (`InlineImageStore`) | `GmailMessage` + `MessageParser.parse(_:).attachments` to re-map `partId` → `attachmentId` after a 404 (architecture §9.4, §14 #13) |
| 10 `AttachmentOpener` | same re-resolve path as 08 |
| 14 QA | the fixture files of §5 (copied into the app test bundle by `project.yml`) |

---

## 2. Files

Every file this module creates. Kind `new` = created by this module. No existing file is modified.

| Path | Kind | Purpose |
|---|---|---|
| `Packages/MailCore/Sources/MailCore/Gmail/GmailDTO.swift` | new | all `Codable` Gmail shapes, `StringUInt64`, `StringInt64`, `GmailFormat`, `gmailMetadataHeaders` |
| `Packages/MailCore/Sources/MailCore/Gmail/MessageParser.swift` | new | `ParsedHeaders`, `ParsedAttachment`, `ParsedBody`, `ParsedMessage`, `MessageParser`, internal `SnippetEntities` |
| `Packages/MailCore/Sources/MailCore/Gmail/BatchCodec.swift` | new | `BatchCall`, `BatchPartResponse`, `BatchCodecError`, `BatchCodec` |
| `Packages/MailCore/Tests/MailCoreTests/GmailDTOTests.swift` | new | DTO decoding/encoding tests (§7) |
| `Packages/MailCore/Tests/MailCoreTests/MessageParserTests.swift` | new | parser tests over shapes (a)–(h), metadata, charsets, snippet |
| `Packages/MailCore/Tests/MailCoreTests/BatchCodecTests.swift` | new | encoder byte-exactness, decoder cases |
| `Packages/MailCore/Tests/MailCoreTests/Support/GmailFixtures.swift` | new | test-only fixture loader (`gmailFixture(_:)`, `gmailJSON(_:as:)`, `crlf(_:)`) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/profile.json` | new | `users.getProfile` response |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/labels.list.json` | new | `labels.list` response (5 labels) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/labels.get.inbox.json` | new | `labels.get` system label with counts, no colour |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/labels.get.user.json` | new | `labels.get` user label with counts and colour |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.list.inbox.1.json` | new | first page with `nextPageToken` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.list.inbox.2.json` | new | last page, `messages` absent |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.metadata.plain.json` | new | `format=metadata` + `fields` mask, bare text/plain |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.metadata.multipart.json` | new | metadata with Cc, Reply-To, In-Reply-To, References, `Message-Id` casing |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.metadata.nonascii.json` | new | RFC 2047 B/Q names and subject, quoted display name with comma |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.metadata.folded-references.json` | new | folded `References`/`Subject`, multi-id `In-Reply-To` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.metadata.no-message-id.json` | new | no Message-ID/Subject/labelIds/snippet, empty group in To |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.a.json` | new | shape (a): bare `text/plain`, no charset |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.b.json` | new | shape (b): `multipart/alternative`, ISO-8859-1 plain + UTF-8 html |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.c.json` | new | shape (c): `multipart/mixed` with PDF and a text attachment |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.d.json` | new | shape (d): `multipart/related` with inline PNG (`Content-ID`) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.e.json` | new | shape (e): Outlook nesting, windows-1252, inline GIF delivered in `data`, PDF |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.f.json` | new | shape (f): `multipart/signed` with `smime.p7s` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.g.json` | new | shape (g): `multipart/report` with `message/delivery-status` and `message/rfc822` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.h.json` | new | shape (h): html part delivered by `attachmentId` only |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/messages.get.full.large-text-attachmentid.json` | new | bare `text/plain` payload delivered by `attachmentId` only |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/threads.get.full.json` | new | `threads.get?format=full` with two messages |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/attachments.get.png.json` | new | `attachments.get` body (`size`, `data`) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/attachments.get.pdf.json` | new | same, PDF bytes |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.empty.json` | new | no `history`, `historyId` only |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.added.json` | new | one `messagesAdded` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.deleted.json` | new | one `messagesDeleted` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.labels.json` | new | `labelsRemoved` + `labelsAdded` with `message.labelIds` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.mixed.json` | new | added + label change + deleted |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.added-then-deleted.json` | new | same id added then deleted |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.paged-1.json` | new | page with `nextPageToken` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.paged-2.json` | new | last page |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.own-modify-echo.json` | new | echo of own `threads.modify`; one record without `message.labelIds` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.trash.json` | new | trash = `labelsAdded: ["TRASH"]` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/history.404.json` | new | `NOT_FOUND` error envelope |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/error.401.json` | new | probe envelope `[gmail-api Common facts]` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/error.403-rate.json` | new | `userRateLimitExceeded` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/error.403-admin.json` | new | `insufficientPermissions` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/error.429.json` | new | `rateLimitExceeded` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/error.500.json` | new | `backendError` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/error.400-invalid-history.json` | new | `failedPrecondition`, message mentions `startHistoryId` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/threads.modify.response.json` | new | `Thread` with `messages[].labelIds` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/send.response.json` | new | minimal sent `Message` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/sendas.list.json` | new | primary + alias |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/batch.request.sample.txt` | new | `[gmail-api §12]` request sample (LF in git; tests convert to CRLF) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/batch.response.sample.txt` | new | `[gmail-api §12]` response sample (200 + 401 parts) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/batch.response.mixed.txt` | new | out-of-order ids, 404/200/429/204 parts |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/batch.response.all-fail.txt` | new | preamble + three 500 parts |

Fixture files live inside the test target (architecture §1.5: "SwiftPM rejects resources outside the target") and are loaded with `Bundle.module.url(forResource:withExtension:subdirectory: "Fixtures/gmail")` exactly as spec 01 §7.1 loads `Fixtures/vectors/smoke.json`. Text fixtures are committed with LF line endings; `crlf(_:)` in `GmailFixtures.swift` converts every `\n` to `\r\n` before use, so `core.autocrlf` settings cannot break the byte-exact tests.

---

## 3. Public interface

### 3.1 `Gmail/GmailDTO.swift`

Verbatim from architecture §2.2 except where marked. All types are `public`, `Sendable`, and nonisolated. `Equatable` is added to every DTO (DEVIATION D1: needed by the tests and by module 05's per-part result comparison; purely additive). Unknown JSON keys are ignored (default `Decodable` behaviour); every property except ids is optional so that `fields=` masks, `format=metadata`, `format=minimal` and lenient `threads.modify` responses (`[gmail-api §9]`, UNVERIFIED depth) all decode.

```swift
import Foundation

/// A Gmail `uint64` transported as a JSON string ("1234567"); also accepts a JSON number.
/// Encodes as a decimal string. `[gmail-api gotcha 3]`
public struct StringUInt64: Codable, Sendable, Equatable, Comparable, Hashable, ExpressibleByIntegerLiteral {
    public var value: UInt64
    public init(_ value: UInt64)
    public init(integerLiteral value: UInt64)
    /// Decodes a string (`UInt64(String)` after trimming ASCII whitespace) or a number.
    /// Throws `DecodingError.dataCorrupted` for a string that is not a decimal uint64 (empty, negative, non-digits, > UInt64.max)
    /// and `DecodingError.typeMismatch` for any other JSON value (bool, null, object, array).
    public init(from decoder: any Decoder) throws
    public func encode(to encoder: any Encoder) throws
    public static func < (lhs: StringUInt64, rhs: StringUInt64) -> Bool
}
/// A Gmail `int64` transported as a JSON string ("1757488353000", epoch milliseconds); also accepts a JSON number. Same rules as `StringUInt64`.
public struct StringInt64: Codable, Sendable, Equatable, Comparable, Hashable, ExpressibleByIntegerLiteral {
    public var value: Int64
    public init(_ value: Int64)
    public init(integerLiteral value: Int64)
    public init(from decoder: any Decoder) throws
    public func encode(to encoder: any Encoder) throws
    public static func < (lhs: StringInt64, rhs: StringInt64) -> Bool
}

/// `users.getProfile` response `[gmail-api §1]`.
public struct GmailProfile: Codable, Sendable, Equatable {
    public var emailAddress: String
    public var historyId: StringUInt64
    public init(emailAddress: String, historyId: StringUInt64)
}
/// `Label.color` `[gmail-api §11]`: `#rrggbb` strings; not validated against Gmail's palette.
public struct GmailLabelColor: Codable, Sendable, Equatable {
    public var textColor: String?
    public var backgroundColor: String?
    public init(textColor: String?, backgroundColor: String?)
}
/// `Label` `[gmail-api §10–§11]`. `labels.list` fills id/name/type/visibility only; `labels.get` adds counts and colour.
public struct GmailLabel: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String?                    // "system" | "user"
    public var messageListVisibility: String?   // "show" | "hide"
    public var labelListVisibility: String?     // "labelShow" | "labelShowIfUnread" | "labelHide"
    public var messagesTotal: Int?
    public var messagesUnread: Int?
    public var threadsTotal: Int?
    public var threadsUnread: Int?
    public var color: GmailLabelColor?
    public init(id: String, name: String, type: String? = nil, messageListVisibility: String? = nil, labelListVisibility: String? = nil,
                messagesTotal: Int? = nil, messagesUnread: Int? = nil, threadsTotal: Int? = nil, threadsUnread: Int? = nil, color: GmailLabelColor? = nil)
}
public struct GmailListLabelsResponse: Codable, Sendable, Equatable {
    public var labels: [GmailLabel]?
    public init(labels: [GmailLabel]?)
}
/// `MessagePartHeader` `[gmail-api §5]`.
public struct GmailHeader: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String)
}
/// `MessagePartBody` `[gmail-api §5]`: `data` is base64url of the CTE-decoded part bytes (`[mime-rfc §5.1]`, GWS-CLI-verified, not documented prose).
public struct GmailPartBody: Codable, Sendable, Equatable {
    public var attachmentId: String?
    public var size: Int?
    public var data: String?
    public init(attachmentId: String? = nil, size: Int? = nil, data: String? = nil)
}
/// `MessagePart` `[gmail-api §5]`. Recursive through `parts`.
public struct GmailPart: Codable, Sendable, Equatable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GmailHeader]?
    public var body: GmailPartBody?
    public var parts: [GmailPart]?
    public init(partId: String? = nil, mimeType: String? = nil, filename: String? = nil, headers: [GmailHeader]? = nil, body: GmailPartBody? = nil, parts: [GmailPart]? = nil)
    /// First header whose `name` matches `name` case-insensitively, value passed through `HeaderFolding.unfold`
    /// and trimmed of leading/trailing spaces and tabs. `nil` when `headers` is nil or has no match.
    public func header(_ name: String) -> String?
}
/// `Message` `[gmail-api §5]`. `payload` is absent for `format=minimal`; for `format=metadata` (with the §4.4 `fields` mask) it carries only `mimeType` and `headers`.
public struct GmailMessage: Codable, Sendable, Equatable {
    public var id: String
    public var threadId: String?
    public var labelIds: [String]?
    public var snippet: String?
    public var historyId: StringUInt64?
    public var internalDate: StringInt64?
    public var sizeEstimate: Int?
    public var payload: GmailPart?
    public init(id: String, threadId: String? = nil, labelIds: [String]? = nil, snippet: String? = nil, historyId: StringUInt64? = nil,
                internalDate: StringInt64? = nil, sizeEstimate: Int? = nil, payload: GmailPart? = nil)
}
/// `Thread` `[gmail-api §3, §9]`.
public struct GmailThread: Codable, Sendable, Equatable {
    public var id: String
    public var historyId: StringUInt64?
    public var snippet: String?
    public var messages: [GmailMessage]?
    public init(id: String, historyId: StringUInt64? = nil, snippet: String? = nil, messages: [GmailMessage]? = nil)
}
/// The `{id, threadId[, labelIds]}` shape of `messages.list` entries and history change records `[gmail-api §4, §13]`.
public struct GmailMessageRef: Codable, Sendable, Equatable {
    public var id: String
    public var threadId: String?
    public var labelIds: [String]?
    public init(id: String, threadId: String? = nil, labelIds: [String]? = nil)
}
public struct GmailListMessagesResponse: Codable, Sendable, Equatable {
    public var messages: [GmailMessageRef]?
    public var nextPageToken: String?
    public var resultSizeEstimate: Int?
    public init(messages: [GmailMessageRef]? = nil, nextPageToken: String? = nil, resultSizeEstimate: Int? = nil)
}
public struct GmailHistoryMessageChange: Codable, Sendable, Equatable {
    public var message: GmailMessageRef
    public init(message: GmailMessageRef)
}
public struct GmailHistoryLabelChange: Codable, Sendable, Equatable {
    public var message: GmailMessageRef
    public var labelIds: [String]?
    public init(message: GmailMessageRef, labelIds: [String]?)
}
/// One `History` record `[gmail-api §13]`. The redundant top-level `messages[]` field is not decoded.
public struct GmailHistory: Codable, Sendable, Equatable {
    public var id: StringUInt64
    public var messagesAdded: [GmailHistoryMessageChange]?
    public var messagesDeleted: [GmailHistoryMessageChange]?
    public var labelsAdded: [GmailHistoryLabelChange]?
    public var labelsRemoved: [GmailHistoryLabelChange]?
    public init(id: StringUInt64, messagesAdded: [GmailHistoryMessageChange]? = nil, messagesDeleted: [GmailHistoryMessageChange]? = nil,
                labelsAdded: [GmailHistoryLabelChange]? = nil, labelsRemoved: [GmailHistoryLabelChange]? = nil)
}
public struct GmailListHistoryResponse: Codable, Sendable, Equatable {
    public var history: [GmailHistory]?
    public var nextPageToken: String?
    public var historyId: StringUInt64?
    public init(history: [GmailHistory]? = nil, nextPageToken: String? = nil, historyId: StringUInt64? = nil)
}
/// `SendAs` `[gmail-api §15]`.
public struct GmailSendAs: Codable, Sendable, Equatable {
    public var sendAsEmail: String
    public var displayName: String?
    public var signature: String?
    public var isPrimary: Bool?
    public var isDefault: Bool?
    public var verificationStatus: String?      // "accepted" | "pending"
    public init(sendAsEmail: String, displayName: String? = nil, signature: String? = nil, isPrimary: Bool? = nil, isDefault: Bool? = nil, verificationStatus: String? = nil)
}
public struct GmailListSendAsResponse: Codable, Sendable, Equatable {
    public var sendAs: [GmailSendAs]?
    public init(sendAs: [GmailSendAs]?)
}
/// Body of `threads.modify` / `messages.modify` `[gmail-api §7, §9]`. `nil` arrays are omitted from the JSON.
public struct GmailModifyRequest: Encodable, Sendable, Equatable {
    public var addLabelIds: [String]?
    public var removeLabelIds: [String]?
    public init(addLabelIds: [String]?, removeLabelIds: [String]?)
}
/// Body of `messages.send` (JSON path) `[gmail-api §14]`: `raw` = padded base64url of the RFC 5322 bytes.
public struct GmailSendRequest: Encodable, Sendable, Equatable {
    public var raw: String
    public var threadId: String?
    public init(raw: String, threadId: String?)
}
/// Google error envelope `[gmail-api Common facts]`. Decoding fails (throws) when the body has no `error` object.
public struct GmailErrorEnvelope: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var reason: String?
        public var message: String?
        public init(reason: String?, message: String?)
    }
    public struct Inner: Codable, Sendable, Equatable {
        public var code: Int?
        public var message: String?
        public var status: String?
        public var errors: [Item]?
        public init(code: Int?, message: String?, status: String?, errors: [Item]?)
    }
    public var error: Inner
    public init(error: Inner)
    /// `error.errors?.first?.reason` — the string module 05 maps (`rateLimitExceeded`, `userRateLimitExceeded`, `notFound`, `failedPrecondition`, …).
    public var primaryReason: String? { error.errors?.first?.reason }
}
/// `format=` query value of `messages.get` / `threads.get` `[gmail-api §3, §5]`.
public enum GmailFormat: String, Sendable { case minimal, full, raw, metadata }
/// `metadataHeaders=` values for metadata hydration (architecture §4.4). Order is the wire order.
public let gmailMetadataHeaders = ["From", "To", "Cc", "Reply-To", "Subject", "Date", "Message-ID", "In-Reply-To", "References"]
```

DEVIATION D2 (additive): explicit public memberwise initialisers with defaults on every DTO (architecture lists properties only). Without them, consumers outside the module (tests in 05/06/07/14) could not construct DTOs. `StringUInt64`/`StringInt64` also gain `Hashable`, `ExpressibleByIntegerLiteral` and `init(_:)` for the same reason.

### 3.2 `Gmail/MessageParser.swift`

Verbatim from architecture §2.2 except the two additions marked.

```swift
import Foundation

/// Decoded RFC 5322 headers of one message (`[mime-rfc §5.5]`). Address lists are parsed by `AddressParser` (RFC 2047 already decoded).
public struct ParsedHeaders: Sendable, Equatable {
    public var from: Mailbox?
    public var to: [Mailbox]
    public var cc: [Mailbox]
    public var replyTo: [Mailbox]
    public var subject: String          // RFC 2047-decoded, unfolded, whitespace runs collapsed to one space, trimmed; "" when absent
    public var messageID: String?       // normalised "<…>" or nil
    public var inReplyTo: String?       // first msg-id token of In-Reply-To, normalised; nil when absent/junk
    public var references: [String]     // MessageIDs.split of the unfolded References header; [] when absent
    public init(from: Mailbox?, to: [Mailbox], cc: [Mailbox], replyTo: [Mailbox], subject: String, messageID: String?, inReplyTo: String?, references: [String])
}
/// One fetchable MIME part: a regular attachment, an inline image, or (in `deferredTextParts`) a text body delivered by `attachmentId`.
public struct ParsedAttachment: Sendable, Equatable {
    public var partId: String           // Gmail partId ("" for a bare top-level payload)
    public var filename: String         // Gmail's decoded filename, or the fallback of §4.3 step 6; "" only for deferred text parts
    public var mimeType: String         // lowercased; "application/octet-stream" when Gmail sent none
    public var size: Int                // body.size, else inlineData.count, else 0
    public var contentId: String?       // Content-ID without "<>" (and without surrounding whitespace); nil when absent or empty
    public var attachmentId: String?    // transient id for attachments.get; nil when the bytes came inline
    public var inlineData: Data?        // small parts delivered inline in body.data (base64url-decoded)
    public var charset: String?         // DEVIATION D3: Content-Type charset parameter (lowercased) for text/* parts; nil otherwise
    public init(partId: String, filename: String, mimeType: String, size: Int, contentId: String?, attachmentId: String?, inlineData: Data?, charset: String? = nil)
}
/// Bodies chosen by the tree walk (`[mime-rfc §5.2]`); text is charset-decoded with "\n" line endings.
public struct ParsedBody: Sendable, Equatable {
    public var html: String?
    public var text: String?
    public var deferredTextParts: [ParsedAttachment]   // text parts delivered by attachmentId only (rare, `[mime-rfc §5.2 (h)]`)
    public init(html: String?, text: String?, deferredTextParts: [ParsedAttachment])
}
public struct ParsedMessage: Sendable, Equatable {
    public var id: String
    public var threadId: String          // message.threadId, falling back to message.id (a thread's first message has threadId == id)
    public var historyId: UInt64         // 0 when absent
    public var internalDate: Int64       // epoch ms; 0 when absent
    public var labelIds: [String]        // [] when absent; order as sent
    public var snippet: String           // HTML-entity-decoded (§4.4), trimmed; "" when absent
    public var headers: ParsedHeaders
    public var topMimeType: String?      // payload.mimeType lowercased (present in format=metadata); nil when no payload
    public var body: ParsedBody?         // nil for metadata/minimal (§4.3 step 2)
    public var attachments: [ParsedAttachment]   // every fetchable part in tree order (incl. inline images); [] when body == nil
    public init(id: String, threadId: String, historyId: UInt64, internalDate: Int64, labelIds: [String], snippet: String, headers: ParsedHeaders,
                topMimeType: String?, body: ParsedBody?, attachments: [ParsedAttachment])
}
public enum MessageParser {
    /// Works for `format=metadata` (headers only) and `format=full` (headers + body walk + attachments). Never throws; malformed input degrades to empty fields.
    public static func parse(_ message: GmailMessage) -> ParsedMessage
    /// `part.body.data` → `Base64URL.decode` → charset from the part's Content-Type (`Charsets.decode`) → line endings normalised to "\n".
    /// `nil` when `body.data` is nil or not valid base64url.
    public static func decodeText(_ part: GmailPart) -> String?
    /// DEVIATION D4 (additive): the same decode for bytes obtained from `attachments.get` (deferred text parts, architecture §4.5 `prepareBody`).
    public static func decodeText(bytes: Data, charset: String?) -> String
}
```

`SnippetEntities` (internal `enum`, same file): `static func decode(_ s: String) -> String` — §4.4. Internal because module 02's `Quoting.textFromHTML` has its own entity handling and no other module needs this one.

### 3.3 `Gmail/BatchCodec.swift`

Verbatim from architecture §2.2; `BatchCodecError` added (DEVIATION D5: architecture says `decode` throws without naming the error; module 05 maps every thrown error to `GmailError.batchMalformed`, so the cases exist for tests and logs only).

```swift
import Foundation

/// One inner request of an HTTP batch `[gmail-api §12]`.
public struct BatchCall: Sendable, Equatable {
    public var id: String        // Content-ID token: ASCII, no whitespace, no "<" or ">" (precondition, checked with `precondition` in encode)
    public var method: String    // "GET" | "POST"
    public var path: String      // host-relative, starts with "/gmail/v1/" (precondition: hasPrefix("/")); query string included, already percent-encoded
    public var jsonBody: Data?   // UTF-8 JSON; when non-nil the part carries "Content-Type: application/json"
    public init(id: String, method: String, path: String, jsonBody: Data? = nil)
}
/// One inner response, matched by id (the `Content-ID` minus "<response-" and ">").
public struct BatchPartResponse: Sendable, Equatable {
    public var id: String
    public var status: Int       // inner status line, e.g. 200, 401, 404, 429, 500
    public var body: Data        // inner body bytes without the CRLF that precedes the next delimiter; empty for 204 / header-only parts
    public init(id: String, status: Int, body: Data)
}
public enum BatchCodecError: Error, Sendable, Equatable {
    case noDelimiter                   // "\r\n--<boundary>" never occurs (HTML error page, empty body, wrong boundary)
    case truncated                     // a part started but no further delimiter / close delimiter followed
    case noParts                       // close delimiter found before any part
    case malformedPart(index: Int)     // no blank line between the outer part headers and the inner HTTP message
    case missingContentID(index: Int)  // outer part headers carry no Content-ID
    case badStatusLine(index: Int)     // inner first line is not "HTTP/x.y <int> …"
}
public enum BatchCodec {
    /// Byte-exact `multipart/mixed` body of §4.5; CRLF everywhere; closes with "--<boundary>--\r\n". Empty `calls` → "--<boundary>--\r\n".
    public static func encode(_ calls: [BatchCall], boundary: String) -> Data
    /// `boundary` parameter of a `multipart/*` Content-Type (quotes stripped by `ContentTypeParams`); nil when the type is not `multipart/*` or the parameter is missing/empty.
    public static func boundary(fromContentType ct: String) -> String?
    /// Splits on "\r\n--<boundary>", reads each part's outer `Content-ID`, the inner status line and body; parts are returned in wire order (ids identify them; callers never rely on order).
    public static func decode(body: Data, boundary: String) throws -> [BatchPartResponse]
}
```

---

## 4. Behaviour

### 4.1 `StringUInt64` / `StringInt64`

```
init(from decoder):
  c = decoder.singleValueContainer()
  if let s = try? c.decode(String.self):
      t = s.trimmingCharacters(in: .whitespaces)             // spaces and tabs only
      guard let v = UInt64(t) else throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected uint64 string, got \"\(s)\"")
      value = v
  else if let n = try? c.decode(UInt64.self): value = n     // JSON number without fraction/exponent
  else throw DecodingError.typeMismatch(UInt64.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "expected string or number"))
encode(to): singleValueContainer().encode(String(value))
<  : lhs.value < rhs.value
```
`StringInt64` is identical with `Int64`. Edge cases: `"+5"` → `UInt64("+5")` is `5` (accepted); `"1.0"`, `""`, `"-1"` (for the unsigned type), `"1e3"`, `"0x10"` → `dataCorrupted`; `true`/`null`/`{}` → `typeMismatch`; a JSON number with a fraction (`1.5`) → `typeMismatch` (Foundation refuses to decode it as an integer; `try?` swallows it and the final throw applies).

### 4.2 `GmailPart.header(_:)`

```
header(name):
  guard let headers else return nil
  wanted = name.lowercased()
  for h in headers where h.name.lowercased() == wanted:
      return HeaderFolding.unfold(h.value).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
  return nil
```
First match wins (a message with two `Received` headers returns the first; the app never asks for repeated headers). Gmail normally returns unfolded values; unfolding is applied anyway because `References` has been observed folded (`[mime-rfc §5.5]`).

### 4.3 `MessageParser.parse(_:)`

Inputs: one `GmailMessage` of any format. Output: `ParsedMessage`. Never throws. Pure, no allocation beyond the output. Performance: linear in the JSON size; base64url decoding of a 2 MiB HTML part must complete in < 30 ms on an iPhone 12-class device (it is one `Base64URL.decode` call — no per-character `String` building).

```
parse(m):
  1. identity
     id = m.id
     threadId = m.threadId ?? m.id
     historyId = m.historyId?.value ?? 0
     internalDate = m.internalDate?.value ?? 0
     labelIds = m.labelIds ?? []
     snippet = SnippetEntities.decode(m.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  2. headers (payload may be nil → all empty)
     p = m.payload
     from     = p?.header("From").flatMap(AddressParser.parseFirst)
     to       = p?.header("To").map(AddressParser.parseList) ?? []
     cc       = p?.header("Cc").map(AddressParser.parseList) ?? []
     replyTo  = p?.header("Reply-To").map(AddressParser.parseList) ?? []
     subject  = collapseWhitespace(RFC2047.decode(p?.header("Subject") ?? ""))       // runs of [space, tab] → one space; trimmed
     messageID = p?.header("Message-ID").flatMap(MessageIDs.normalize)               // header() is case-insensitive → "Message-Id" also matches
     inReplyTo = p?.header("In-Reply-To").flatMap { MessageIDs.split($0).first }.flatMap(MessageIDs.normalize)
     references = p?.header("References").map(MessageIDs.split) ?? []
     topMimeType = p?.mimeType?.lowercased()
  3. format detection
     isMetadataOnly = (p == nil) || (p.parts == nil && p.body?.data == nil && p.body?.attachmentId == nil)
     if isMetadataOnly: body = nil; attachments = []; return
  4. tree walk (§4.3.1) starting at p with an empty Context; then
     body = ParsedBody(html: ctx.html, text: ctx.text, deferredTextParts: ctx.deferred)
     attachments = ctx.attachments
```
Step 3 covers `format=metadata` (`payload` = `{mimeType, headers}` under the §4.4 fields mask, or `{partId, mimeType, filename, headers, body:{size:0}}` without the mask — `[gmail-api §3]` notes the empty-body shape is UNVERIFIED, so both are treated identically) and `format=minimal` (`payload` absent). A `format=full` message whose only part has neither `data` nor `attachmentId` (an empty mail) is also classified metadata-only; module 07's `prepareBody` then falls back to the snippet — the correct rendering for an empty body.

#### 4.3.1 Tree walk (`[mime-rfc §5.2]`, GWS-CLI rules)

```
struct Context { var html: String?; var text: String?; var deferred: [ParsedAttachment] = []; var attachments: [ParsedAttachment] = [] }

collect(part, &ctx):
  ct       = (part.mimeType ?? "application/octet-stream").lowercased()
  ctParams = ContentTypeParams.parse(part.header("Content-Type") ?? "")
  charset  = ct.hasPrefix("text/") ? ctParams.param("charset")?.lowercased() : nil
  cid      = part.header("Content-ID").map(stripAngleBrackets).flatMap { $0.isEmpty ? nil : $0 }
  disp     = part.header("Content-Disposition").map(ContentTypeParams.parse)     // disp.type = "attachment" | "inline" | ""
  filename = fallbackFilename(part, ctParams, disp)                              // step 6
  hasData  = (part.body?.data?.isEmpty == false)
  attId    = part.body?.attachmentId (nil when empty string)

  a) if let attId:                                       // any fetchable blob; never recurse
        att = ParsedAttachment(partId: part.partId ?? "", filename: filename, mimeType: ct, size: part.body?.size ?? 0,
                               contentId: cid, attachmentId: attId, inlineData: nil, charset: charset)
        if ct.hasPrefix("text/") && (part.filename ?? "").isEmpty && cid == nil:
              att.filename = ""; ctx.deferred.append(att)  // large text body delivered as attachment [mime-rfc §5.2 (h)]
        else: ctx.attachments.append(att)
        return
  b) if ct.hasPrefix("multipart/"):                       // alternative, mixed, related, signed, report, …
        for child in part.parts ?? []: collect(child, &ctx)
        return
  c) if ct == "text/html" && ctx.html == nil && (part.filename ?? "").isEmpty:
        ctx.html = decodeText(part); return
  d) if ct == "text/plain" && ctx.text == nil && (part.filename ?? "").isEmpty:
        ctx.text = decodeText(part); return
  e) if hasData && (!(part.filename ?? "").isEmpty || cid != nil):     // small attachment / inline image delivered inline in data
        bytes = Base64URL.decode(part.body!.data!) ?? Data()
        ctx.attachments.append(ParsedAttachment(partId: part.partId ?? "", filename: filename, mimeType: ct, size: part.body?.size ?? bytes.count,
                                                contentId: cid, attachmentId: nil, inlineData: bytes, charset: charset))
        return
  f) otherwise: ignore (examples: `message/delivery-status` text, a second `text/html` alternative, `text/calendar` without filename, `message/rfc822` expanded into `parts` without an attachmentId — see §10 A4)
```

Rules and edge cases:
1. First `text/html` and first `text/plain` body-text parts win, in tree order (GWS-CLI `extract_payload_recursive`; RFC 2046 §5.1.4 "last alternative" is deliberately not followed — deterministic and matches Google's own client).
2. A text part with a non-empty `filename` is an attachment (c/d fail, a or e apply): `notes.txt` in shape (c).
3. `Content-Disposition` does not decide inline vs attachment (`[mime-rfc §5.4]`: "the HTML reference, not the disposition, decides"); `contentId` is recorded on every attachment that has one and module 08's sanitizer decides via `referencedContentIDs` (architecture §4.5 `isInline`).
4. `message/rfc822` is never recursed: with an `attachmentId` it becomes an attachment (rule a); without one it is ignored (rule f).
5. `stripAngleBrackets(v)`: trim spaces/tabs; drop one leading `<` and one trailing `>` if both present; trim again. `"<ii_logo>"` → `"ii_logo"`; `"image001.gif@01DB"` → unchanged; `"<>"` → `""` → nil.
6. `fallbackFilename`: `part.filename` when non-empty (Gmail already decodes RFC 2047/2231, `[mime-rfc §2.4]`); else `RFC2231.parameter(named: "filename", in: disp?.params ?? [])`; else `RFC2231.parameter(named: "name", in: ctParams.params)`; else `"attachment-\(part.partId ?? "")"`. Result is trimmed; the fallback is used only for attachments (rule a non-text or rule e), never for deferred text parts (their filename is forced to `""`).
7. `size` for rule a is `body.size ?? 0` (the pre-encoding byte count Gmail reports); for rule e `body.size ?? bytes.count`.
8. `parts` order is preserved; `attachments` therefore lists Outlook's inline image before the trailing PDF in shape (e).
9. Depth is unbounded by design (recursion over `parts`); Gmail nests at most a handful of levels. No cycle is possible in decoded JSON.

#### 4.3.2 `decodeText(_ part:)` and `decodeText(bytes:charset:)` (`[mime-rfc §5.3]`)

```
decodeText(part):
  guard let data = part.body?.data, let bytes = Base64URL.decode(data) else return nil
  charset = ContentTypeParams.parse(part.header("Content-Type") ?? "").param("charset")
  return decodeText(bytes: bytes, charset: charset)

decodeText(bytes, charset):
  s = Charsets.decode(bytes, charset: charset)          // charset → utf8 → isoLatin1, never fails (02)
  return normalizeLineEndings(s)                        // "\r\n" → "\n", then remaining "\r" → "\n"
```
- Missing charset → `Charsets.decode(bytes, charset: nil)` = UTF-8 with Latin-1 fallback (research says default `us-ascii`; UTF-8 is a superset for ASCII input).
- Unknown charset name (`x-unknown`) → the same fallback chain inside `Charsets.decode`.
- A `<meta charset>` inside the HTML that disagrees is ignored; the MIME header wins.
- An empty `data` string (`""`) decodes to `""` (not nil) — `Base64URL.decode("")` returns empty `Data`.
- Base64url with or without padding is accepted (`[mime-rfc §8.3]`); characters outside both alphabets → `Base64URL.decode` returns nil → `decodeText` returns nil (rule c/d then leaves the slot empty and a later part may fill it).

### 4.4 `SnippetEntities.decode`

Gmail snippets are HTML-escaped (`&amp;`, `&#39;`, `&quot;`, `&lt;`, `&gt;`) — architecture §3.3 requires the stored snippet to be entity-decoded. Single left-to-right pass:

```
decode(s):
  if !s.contains("&"): return s
  out = ""; i = start
  while i < end:
    if s[i] == "&", let semi = index of ";" within the next 1…32 characters after i:
        name = s[i+1 ..< semi]
        replacement =
          named[name] if present                      // amp → "&", lt → "<", gt → ">", quot → "\"", apos → "'", nbsp → " " (U+0020)
          else if name hasPrefix "#x" or "#X": UInt32(hexdigits, radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
          else if name hasPrefix "#": UInt32(decimaldigits, radix: 10).flatMap(Unicode.Scalar.init).map(String.init)
          else nil
        if let replacement: out += replacement; i = semi + 1; continue
    out.append(s[i]); i += 1
  return out
```
Table: `"Hi Bob &amp; team, it&#39;s done."` → `Hi Bob & team, it's done.`; `"&quot;Quoted&quot; &lt;b&gt;"` → `"Quoted" <b>`; `"&amp;lt;"` → `&lt;` (single pass, never double-decodes); `"caf&#233;"` → `café`; `"&#x1F600;"` → 😀; `"&unknown; &"` → unchanged; `"&#99999999;"` (not a scalar) → unchanged; `"a&nbsp;b"` → `a b`.

### 4.5 `BatchCodec.encode`

For `calls = [c1 … cn]` and `boundary = B` the output is exactly (`⏎` = CRLF, no other line endings anywhere):

```
--B⏎
Content-Type: application/http⏎
Content-ID: <{c.id}>⏎
⏎
{c.method} {c.path}⏎
[Content-Type: application/json⏎          only when c.jsonBody != nil
⏎
{c.jsonBody bytes}⏎]
⏎
… repeated per call …
--B--⏎
```
So a GET part ends `GET /path⏎⏎--B` (one blank line) and a POST part ends `{json}⏎⏎--B`; this reproduces `[gmail-api §12]`'s request sample byte for byte (fixture `batch.request.sample.txt`) and is what the live probe accepted. No `Content-Length`, no `Content-Transfer-Encoding: binary` — the probe sample has neither. Preconditions (`precondition`): `c.path.hasPrefix("/")`, `c.id` non-empty and free of `<`, `>`, whitespace, CR, LF; `boundary` non-empty, ≤ 70 chars, ASCII (RFC 2046 §5.1.1 — module 05 generates `batch_minimail_<16 hex>`). The outer `Content-Type: multipart/mixed; boundary=B` header and `Authorization` are module 05's job. Output built as `[UInt8]` then wrapped in `Data`; never through `String` line-ending normalisation.

### 4.6 `BatchCodec.boundary(fromContentType:)`

```
v = ContentTypeParams.parse(ct)
guard v.type.lowercased().hasPrefix("multipart/"), let b = v.param("boundary"), !b.isEmpty else return nil
return b
```
`"multipart/mixed; boundary=batch_abc"` → `batch_abc`; `"multipart/mixed; boundary=\"batch_abc\"; charset=UTF-8"` → `batch_abc` (quotes stripped by `ContentTypeParams`); `"application/json; charset=UTF-8"` → nil (module 05 then treats the response as a non-batch error body); `"multipart/mixed"` → nil.

### 4.7 `BatchCodec.decode`

```
decode(body, boundary):
  bytes  = [0x0D, 0x0A] + [UInt8](body)                  // the first delimiter is "--B" at offset 0 without a leading CRLF; prepending CRLF makes every delimiter "\r\n--B"
  delim  = [UInt8]("\r\n--\(boundary)".utf8)
  CRLF   = [0x0D, 0x0A]; CRLFCRLF = CRLF + CRLF
  guard var cur = firstRange(delim, in: bytes, from: 0) else throw .noDelimiter
  parts = []
  loop:
    after = cur.upperBound
    if bytes[after...].starts(with: "--".utf8): break        // close delimiter "--B--"
    guard let eol = firstRange(CRLF, in: bytes, from: after) else throw .truncated   // transport padding (spaces) before this CRLF is ignored
    start = eol.upperBound
    guard let next = firstRange(delim, in: bytes, from: start) else throw .truncated
    parts.append(try parsePart(bytes[start ..< next.lowerBound], index: parts.count))
    cur = next
  if parts.isEmpty: throw .noParts
  return parts

parsePart(slice, index):
  guard let sep = firstRange(CRLFCRLF, in: slice) else throw .malformedPart(index: index)
  outer = slice[..<sep.lowerBound]; inner = slice[sep.upperBound...]
  id: for line in outer split on CRLF: if line's name (before ":") lowercased == "content-id":
        v = value trimmed of spaces/tabs; strip one leading "<" and one trailing ">"; if v.hasPrefix("response-") drop it
      none found or empty → throw .missingContentID(index: index)
  statusLine = inner up to first CRLF (or all of inner)
  tokens = statusLine split on single spaces, empty tokens removed
  guard tokens.count >= 2, tokens[0].hasPrefix("HTTP/"), let status = Int(tokens[1]) else throw .badStatusLine(index: index)
  rest = inner after that CRLF (empty if none)
  bodyBytes = if let b = firstRange(CRLFCRLF, in: rest): rest[b.upperBound...] else: []      // header-only part (204) → empty body
  return BatchPartResponse(id: id, status: status, body: Data(bodyBytes))
```
`firstRange(_ pattern:in:from:)` is a private naive byte search (outer loop over positions, inner compare) — no Foundation `Data.range(of:)` (its Linux availability is not relied upon). Complexity O(n·m) with m ≤ 80; a 25-part full-message batch (≈ 5 MB) scans in well under 50 ms.

Edge cases: a preamble before the first delimiter is skipped (fixture `all-fail`); parts arrive in any order (fixture `mixed`); fewer parts than requests → shorter array (module 05 marks the missing ids `batchMalformed`); an `Content-ID` without the `response-` prefix is accepted as-is; inner headers are not returned (module 05 reads `Retry-After` from the outer HTTP response only — a per-part `Retry-After` is ignored, architecture §6.3 uses `Backoff.transient` for per-part retries); the body keeps any trailing whitespace Google adds after the JSON (JSONDecoder tolerates it); LF-only input (no CR) → `.noDelimiter` (Google always sends CRLF, `[gmail-api §12]`); an outer status ≠ 200 never reaches `decode` (module 05 maps it first).

### 4.8 Concurrency and isolation

Everything is a value type or a caseless `enum` with static functions; no shared state, no `actor`, no `@MainActor`. All public types are `Sendable` by structure (`Data`, `String`, `Int`, arrays of `Sendable`). Safe to call from `GmailClient`, `SyncEngine`, `Outbox` and `InlineImageStore` actors concurrently.

---

## 5. Data

### 5.1 JSON encoding of requests (module 05 uses `JSONEncoder` with `.sortedKeys` and `.withoutEscapingSlashes`)

| Value | Bytes |
|---|---|
| `GmailModifyRequest(addLabelIds: nil, removeLabelIds: ["INBOX"])` | `{"removeLabelIds":["INBOX"]}` |
| `GmailModifyRequest(addLabelIds: ["UNREAD"], removeLabelIds: ["INBOX"])` | `{"addLabelIds":["UNREAD"],"removeLabelIds":["INBOX"]}` |
| `GmailSendRequest(raw: "RnJvbQ==", threadId: "a1")` | `{"raw":"RnJvbQ==","threadId":"a1"}` |
| `GmailSendRequest(raw: "RnJvbQ==", threadId: nil)` | `{"raw":"RnJvbQ=="}` |
| `StringUInt64(1234567)` | `"1234567"` |

### 5.2 Fixture contents — DTO responses (`Fixtures/gmail/`)

All JSON fixtures are valid JSON (`python3 -m json.tool` passes). Whitespace is free; values are load-bearing.

`profile.json`
```json
{"emailAddress":"user@example.com","messagesTotal":12345,"threadsTotal":6789,"historyId":"1234567"}
```
`labels.list.json` (`[gmail-api §10]`)
```json
{"labels":[
 {"id":"INBOX","name":"INBOX","messageListVisibility":"hide","labelListVisibility":"labelShow","type":"system"},
 {"id":"UNREAD","name":"UNREAD","type":"system"},
 {"id":"SENT","name":"SENT","messageListVisibility":"hide","labelListVisibility":"labelShow","type":"system"},
 {"id":"CATEGORY_PERSONAL","name":"CATEGORY_PERSONAL","type":"system"},
 {"id":"Label_12","name":"Customers/ACME","messageListVisibility":"show","labelListVisibility":"labelShow","type":"user"}]}
```
`labels.get.inbox.json`
```json
{"id":"INBOX","name":"INBOX","type":"system","messageListVisibility":"hide","labelListVisibility":"labelShow","messagesTotal":1200,"messagesUnread":7,"threadsTotal":900,"threadsUnread":5}
```
`labels.get.user.json` (`[gmail-api §11]`)
```json
{"id":"Label_12","name":"Customers/ACME","type":"user","messageListVisibility":"show","labelListVisibility":"labelShow","messagesTotal":120,"messagesUnread":3,"threadsTotal":44,"threadsUnread":2,"color":{"textColor":"#ffffff","backgroundColor":"#4a86e8"}}
```
`messages.list.inbox.1.json`
```json
{"messages":[{"id":"a1","threadId":"a1"},{"id":"b1","threadId":"b1"},{"id":"c1","threadId":"c1"}],"nextPageToken":"page-2","resultSizeEstimate":201}
```
`messages.list.inbox.2.json`
```json
{"resultSizeEstimate":0}
```
`attachments.get.png.json` — bytes `89 50 4E 47 0D 0A 1A 0A 46 41 4B 45` (12 bytes)
```json
{"size":12,"data":"iVBORw0KGgpGQUtF"}
```
`attachments.get.pdf.json` — bytes of `%PDF-1.4\nFAKE\n%%EOF\n` (20 bytes)
```json
{"size":20,"data":"JVBERi0xLjQKRkFLRQolJUVPRgo"}
```
`threads.modify.response.json`
```json
{"id":"a1","historyId":"1200","messages":[{"id":"a1","threadId":"a1","labelIds":["INBOX"]},{"id":"a2","threadId":"a1","labelIds":["SENT"]}]}
```
`send.response.json`
```json
{"id":"s1","threadId":"a1","labelIds":["SENT"]}
```
`sendas.list.json`
```json
{"sendAs":[
 {"sendAsEmail":"user@example.com","displayName":"Max Mustermann","signature":"<div dir=\"ltr\">Max Mustermann<br>example</div>","isPrimary":true,"isDefault":true,"verificationStatus":"accepted"},
 {"sendAsEmail":"m.mustermann@example.com","displayName":"Max Mustermann","treatAsAlias":true,"verificationStatus":"accepted"}]}
```

### 5.3 Fixture contents — history (`[gmail-api §13]`; consumed by module 07's `HistoryReducerTests` with the semantics noted)

`history.empty.json` — no changes; `historyId` present even without `history` (UNVERIFIED `[gmail-api §13 item 3]`, the fixture asserts our decoder tolerates both)
```json
{"historyId":"2000"}
```
`history.added.json`
```json
{"history":[{"id":"2001","messages":[{"id":"n1","threadId":"n1"}],"messagesAdded":[{"message":{"id":"n1","threadId":"n1","labelIds":["UNREAD","INBOX"]}}]}],"historyId":"2001"}
```
`history.deleted.json`
```json
{"history":[{"id":"2002","messages":[{"id":"a1","threadId":"a1"}],"messagesDeleted":[{"message":{"id":"a1","threadId":"a1"}}]}],"historyId":"2002"}
```
`history.labels.json` — read a1 (final labels `["INBOX"]`), then label b1
```json
{"history":[
 {"id":"2003","messages":[{"id":"a1","threadId":"a1"}],"labelsRemoved":[{"message":{"id":"a1","threadId":"a1","labelIds":["INBOX"]},"labelIds":["UNREAD"]}]},
 {"id":"2004","messages":[{"id":"b1","threadId":"b1"}],"labelsAdded":[{"message":{"id":"b1","threadId":"b1","labelIds":["INBOX","Label_12"]},"labelIds":["Label_12"]}]}],
 "historyId":"2004"}
```
`history.mixed.json` — n2 added, a1 archived elsewhere, c1 permanently deleted
```json
{"history":[
 {"id":"2005","messagesAdded":[{"message":{"id":"n2","threadId":"n2","labelIds":["INBOX"]}}]},
 {"id":"2007","labelsRemoved":[{"message":{"id":"a1","threadId":"a1","labelIds":["UNREAD"]},"labelIds":["INBOX"]}]},
 {"id":"2010","messagesDeleted":[{"message":{"id":"c1","threadId":"c1"}}]}],
 "historyId":"2010"}
```
`history.added-then-deleted.json`
```json
{"history":[
 {"id":"2011","messagesAdded":[{"message":{"id":"n3","threadId":"n3","labelIds":["INBOX","UNREAD"]}}]},
 {"id":"2012","messagesDeleted":[{"message":{"id":"n3","threadId":"n3"}}]}],
 "historyId":"2012"}
```
`history.paged-1.json`
```json
{"history":[{"id":"2020","messagesAdded":[{"message":{"id":"n4","threadId":"n4","labelIds":["INBOX","UNREAD"]}}]}],"nextPageToken":"hp2","historyId":"2025"}
```
`history.paged-2.json`
```json
{"history":[{"id":"2021","labelsAdded":[{"message":{"id":"n4","threadId":"n4","labelIds":["INBOX","UNREAD","STARRED"]},"labelIds":["STARRED"]}]}],"historyId":"2025"}
```
`history.own-modify-echo.json` — record 2030 is the echo of our `threads.modify removeLabelIds:["UNREAD"]`; record 2031 lacks `message.labelIds` (architecture §14 #8)
```json
{"history":[
 {"id":"2030","labelsRemoved":[{"message":{"id":"a1","threadId":"a1","labelIds":["INBOX"]},"labelIds":["UNREAD"]}]},
 {"id":"2031","labelsRemoved":[{"message":{"id":"b1","threadId":"b1"},"labelIds":["INBOX"]}]}],
 "historyId":"2031"}
```
`history.trash.json` — trashing = label change, not `messagesDeleted` (`[gmail-api gotcha 6]`)
```json
{"history":[{"id":"2040","labelsAdded":[{"message":{"id":"b1","threadId":"b1","labelIds":["TRASH","UNREAD"]},"labelIds":["TRASH"]}],"labelsRemoved":[{"message":{"id":"b1","threadId":"b1","labelIds":["TRASH","UNREAD"]},"labelIds":["INBOX"]}]}],"historyId":"2040"}
```
`history.404.json`
```json
{"error":{"code":404,"message":"Requested entity was not found.","errors":[{"message":"Requested entity was not found.","domain":"global","reason":"notFound"}],"status":"NOT_FOUND"}}
```

### 5.4 Fixture contents — error envelopes

`error.401.json` (`[gmail-api Common facts]`, probe)
```json
{"error":{"code":401,"message":"Request is missing required authentication credential. Expected OAuth 2 access token, login cookie or other valid authentication credential.","errors":[{"message":"Login Required.","domain":"global","reason":"required","location":"Authorization","locationType":"header"}],"status":"UNAUTHENTICATED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"CREDENTIALS_MISSING","domain":"googleapis.com","metadata":{"service":"gmail.googleapis.com","method":"google.gmail.v1.GmailService.GetProfile"}}]}}
```
`error.403-rate.json`
```json
{"error":{"code":403,"message":"User-rate limit exceeded.  Retry after 2026-09-11T10:00:00.000Z","errors":[{"message":"User-rate limit exceeded.  Retry after 2026-09-11T10:00:00.000Z","domain":"usageLimits","reason":"userRateLimitExceeded"}],"status":"PERMISSION_DENIED"}}
```
`error.403-admin.json`
```json
{"error":{"code":403,"message":"Request had insufficient authentication scopes.","errors":[{"message":"Insufficient Permission","domain":"global","reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED"}}
```
`error.429.json`
```json
{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","errors":[{"message":"Resource has been exhausted (e.g. check quota).","domain":"global","reason":"rateLimitExceeded"}],"status":"RESOURCE_EXHAUSTED"}}
```
`error.500.json`
```json
{"error":{"code":500,"message":"Backend Error","errors":[{"message":"Backend Error","domain":"global","reason":"backendError"}],"status":"INTERNAL"}}
```
`error.400-invalid-history.json` (the 400 code for a malformed id is UNVERIFIED `[gmail-api §13 item 5]`; module 05 maps it by reason and by the word `historyId` in the message)
```json
{"error":{"code":400,"message":"Invalid startHistoryId: 1","errors":[{"message":"Invalid startHistoryId: 1","domain":"global","reason":"failedPrecondition"}],"status":"FAILED_PRECONDITION"}}
```

### 5.5 Fixture contents — `format=metadata` messages (shape = the §4.4 `fields` mask: `id,threadId,labelIds,snippet,historyId,internalDate,payload/mimeType,payload/headers`)

`messages.get.metadata.plain.json`
```json
{"id":"m-plain","threadId":"t-plain","labelIds":["INBOX","UNREAD"],"snippet":"Hi Bob &amp; team, it&#39;s done.","historyId":"1001","internalDate":"1757488353000",
 "payload":{"mimeType":"text/plain","headers":[
  {"name":"From","value":"Alice <alice@example.com>"},
  {"name":"To","value":"user@example.com"},
  {"name":"Subject","value":"Plain hello"},
  {"name":"Date","value":"Thu, 10 Sep 2026 09:12:33 +0200"},
  {"name":"Message-ID","value":"<m-plain@example.com>"}]}}
```
`messages.get.metadata.multipart.json`
```json
{"id":"m-multi","threadId":"t-multi","labelIds":["INBOX"],"snippet":"Invoice attached.","historyId":"1002","internalDate":"1757490000000",
 "payload":{"mimeType":"multipart/mixed","headers":[
  {"name":"From","value":"Alice <alice@example.com>"},
  {"name":"To","value":"user@example.com, Bob <bob@example.com>"},
  {"name":"Cc","value":"carol@example.com"},
  {"name":"Reply-To","value":"Alice Support <support@example.com>"},
  {"name":"Subject","value":"Re: Invoice 42"},
  {"name":"Date","value":"Thu, 10 Sep 2026 09:40:00 +0200"},
  {"name":"Message-Id","value":"<m-multi@example.com>"},
  {"name":"In-Reply-To","value":"<m-plain@example.com>"},
  {"name":"References","value":"<root@example.com> <m-plain@example.com>"}]}}
```
`messages.get.metadata.nonascii.json` (`[mime-rfc §8.3]` RFC 2047 rows; raw UTF-8 in JSON is fine)
```json
{"id":"m-nonascii","threadId":"t-nonascii","labelIds":["INBOX","UNREAD","Label_12"],"snippet":"Grüße aus Köln &amp; Umgebung","historyId":"1003","internalDate":"1757491000000",
 "payload":{"mimeType":"multipart/alternative","headers":[
  {"name":"From","value":"=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?= <alice@example.com>"},
  {"name":"To","value":"\"Müller, Bob\" <bob@example.com>, =?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?= <keld@example.com>"},
  {"name":"Subject","value":"=?utf-8?q?Gr=C3=BC=C3=9Fe_aus_K=C3=B6ln?="},
  {"name":"Date","value":"Thu, 10 Sep 2026 10:00:00 +0200"},
  {"name":"Message-ID","value":"<m-nonascii@example.com>"}]}}
```
`messages.get.metadata.folded-references.json` (`\r\n` + WSP inside JSON strings are literal escapes)
```json
{"id":"m-folded","threadId":"t-folded","labelIds":["INBOX"],"snippet":"folded","historyId":"1004","internalDate":"1757492000000",
 "payload":{"mimeType":"multipart/alternative","headers":[
  {"name":"From","value":"Dave <dave@example.com>"},
  {"name":"To","value":"user@example.com"},
  {"name":"Subject","value":"Long subject\r\n continued here"},
  {"name":"Message-ID","value":"<m-folded@example.com>"},
  {"name":"In-Reply-To","value":"<r4@example.com> <r3@example.com>"},
  {"name":"References","value":"<r1@example.com>\r\n <r2@example.com>\r\n\t<r3@example.com> junk <r4@example.com>"}]}}
```
`messages.get.metadata.no-message-id.json`
```json
{"id":"m-noid","threadId":"t-noid","historyId":"1005","internalDate":"1757493000000",
 "payload":{"mimeType":"text/html","headers":[
  {"name":"From","value":"noreply@example.com"},
  {"name":"To","value":"undisclosed-recipients:;"},
  {"name":"Date","value":"Thu, 10 Sep 2026 11:00:00 +0200"}]}}
```

### 5.6 Fixture contents — `format=full` messages (shapes (a)–(h) of `[mime-rfc §5.2]`)

Every `data` value below was produced by `base64.urlsafe_b64encode(bytes).rstrip("=")` over the stated bytes (unpadded, as Gmail sends it). `size` = byte count of those bytes.

`messages.get.full.a.json` — (a) bare `text/plain`, Content-Type without charset. Bytes: `Hi Bob & team,\r\nit's done.\r\n` (28)
```json
{"id":"a1","threadId":"a1","labelIds":["UNREAD","INBOX"],"snippet":"Hi Bob &amp; team, it&#39;s done.","historyId":"1101","internalDate":"1757488353000","sizeEstimate":812,
 "payload":{"partId":"","mimeType":"text/plain","filename":"",
  "headers":[{"name":"From","value":"Alice <alice@example.com>"},{"name":"To","value":"user@example.com"},{"name":"Subject","value":"Plain hello"},
             {"name":"Date","value":"Thu, 10 Sep 2026 09:12:33 +0200"},{"name":"Message-ID","value":"<a1@example.com>"},{"name":"Content-Type","value":"text/plain"}],
  "body":{"size":28,"data":"SGkgQm9iICYgdGVhbSwNCml0J3MgZG9uZS4NCg"}}}
```
`messages.get.full.b.json` — (b) `multipart/alternative`; plain = ISO-8859-1 bytes of `Grüße aus Köln\r\n` (16), html = UTF-8 bytes of `<div dir="ltr">Grüße aus Köln<br><b>Alice</b></div>\r\n` (56)
```json
{"id":"b1","threadId":"b1","labelIds":["INBOX"],"snippet":"Grüße aus Köln","historyId":"1102","internalDate":"1757489000000","sizeEstimate":2100,
 "payload":{"partId":"","mimeType":"multipart/alternative","filename":"",
  "headers":[{"name":"From","value":"Alice <alice@example.com>"},{"name":"To","value":"user@example.com"},{"name":"Subject","value":"Alternative"},
             {"name":"Message-ID","value":"<b1@example.com>"},{"name":"Content-Type","value":"multipart/alternative; boundary=\"000000000000abce\""}],
  "body":{"size":0},
  "parts":[
   {"partId":"0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\"ISO-8859-1\""},{"name":"Content-Transfer-Encoding","value":"quoted-printable"}],
    "body":{"size":16,"data":"R3L832UgYXVzIEv2bG4NCg"}},
   {"partId":"1","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=\"UTF-8\""},{"name":"Content-Transfer-Encoding","value":"quoted-printable"}],
    "body":{"size":56,"data":"PGRpdiBkaXI9Imx0ciI-R3LDvMOfZSBhdXMgS8O2bG48YnI-PGI-QWxpY2U8L2I-PC9kaXY-DQo"}}]}}
```
`messages.get.full.c.json` — (c) `multipart/mixed` ⊃ alternative + PDF + text attachment. plain `Invoice attached.\r\n` (19), html `<div>Invoice attached.</div>\r\n` (30)
```json
{"id":"c1","threadId":"c1","labelIds":["INBOX","UNREAD"],"snippet":"Invoice attached.","historyId":"1103","internalDate":"1757490000000","sizeEstimate":45210,
 "payload":{"partId":"","mimeType":"multipart/mixed","filename":"",
  "headers":[{"name":"From","value":"Alice <alice@example.com>"},{"name":"To","value":"user@example.com"},{"name":"Cc","value":"bob@example.com"},{"name":"Subject","value":"Invoice 42"},
             {"name":"Message-ID","value":"<c1@example.com>"},{"name":"Content-Type","value":"multipart/mixed; boundary=\"000000000000abcd\""}],
  "body":{"size":0},
  "parts":[
   {"partId":"0","mimeType":"multipart/alternative","filename":"","headers":[{"name":"Content-Type","value":"multipart/alternative; boundary=\"000000000000abce\""}],"body":{"size":0},
    "parts":[
     {"partId":"0.0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\"UTF-8\""}],"body":{"size":19,"data":"SW52b2ljZSBhdHRhY2hlZC4NCg"}},
     {"partId":"0.1","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=\"UTF-8\""}],"body":{"size":30,"data":"PGRpdj5JbnZvaWNlIGF0dGFjaGVkLjwvZGl2Pg0K"}}]},
   {"partId":"1","mimeType":"application/pdf","filename":"invoice-42.pdf",
    "headers":[{"name":"Content-Type","value":"application/pdf; name=\"invoice-42.pdf\""},{"name":"Content-Disposition","value":"attachment; filename=\"invoice-42.pdf\""},{"name":"Content-Transfer-Encoding","value":"base64"}],
    "body":{"attachmentId":"ANG-pdf-c1","size":38211}},
   {"partId":"2","mimeType":"text/plain","filename":"notes.txt",
    "headers":[{"name":"Content-Type","value":"text/plain; charset=\"utf-8\"; name=\"notes.txt\""},{"name":"Content-Disposition","value":"attachment; filename=\"notes.txt\""}],
    "body":{"attachmentId":"ANG-txt-c1","size":120}}]}}
```
`messages.get.full.d.json` — (d) `multipart/related` with a Gmail inline image. plain `Logo below\r\n` (12), html `<div>Logo below<br><img src="cid:ii_logo" alt="logo"></div>\r\n` (61)
```json
{"id":"d1","threadId":"d1","labelIds":["INBOX"],"snippet":"Logo below","historyId":"1104","internalDate":"1757491000000","sizeEstimate":9000,
 "payload":{"partId":"","mimeType":"multipart/related","filename":"",
  "headers":[{"name":"From","value":"Alice <alice@example.com>"},{"name":"To","value":"user@example.com"},{"name":"Subject","value":"Inline logo"},{"name":"Message-ID","value":"<d1@example.com>"}],
  "body":{"size":0},
  "parts":[
   {"partId":"0","mimeType":"multipart/alternative","filename":"","headers":[],"body":{"size":0},
    "parts":[
     {"partId":"0.0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\"UTF-8\""}],"body":{"size":12,"data":"TG9nbyBiZWxvdw0K"}},
     {"partId":"0.1","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=\"UTF-8\""}],"body":{"size":61,"data":"PGRpdj5Mb2dvIGJlbG93PGJyPjxpbWcgc3JjPSJjaWQ6aWlfbG9nbyIgYWx0PSJsb2dvIj48L2Rpdj4NCg"}}]},
   {"partId":"1","mimeType":"image/png","filename":"logo.png",
    "headers":[{"name":"Content-Type","value":"image/png; name=\"logo.png\""},{"name":"Content-Disposition","value":"inline; filename=\"logo.png\""},{"name":"Content-ID","value":"<ii_logo>"},{"name":"X-Attachment-Id","value":"ii_logo"}],
    "body":{"attachmentId":"ANG-png-d1","size":5120}}]}}
```
`messages.get.full.e.json` — (e) Outlook: mixed ⊃ related ⊃ alternative, inline GIF delivered in `data` with `Content-Disposition: attachment`, trailing PDF. plain = windows-1252 bytes of `Grüße – Outlook\r\n` (17; `–` = 0x96), html = ASCII `<html><body><p>Gr&uuml;&szlig;e &ndash; Outlook</p><img src="cid:image001.gif@01DB"></body></html>\r\n` (100), gif = the 43-byte 1×1 GIF `47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b`
```json
{"id":"e1","threadId":"e1","labelIds":["INBOX"],"snippet":"Grüße – Outlook","historyId":"1105","internalDate":"1757492000000","sizeEstimate":20000,
 "payload":{"partId":"","mimeType":"multipart/mixed","filename":"",
  "headers":[{"name":"From","value":"Erika Beispiel <erika@example.org>"},{"name":"To","value":"user@example.com"},{"name":"Subject","value":"AW: Angebot"},{"name":"Message-ID","value":"<e1@example.org>"}],
  "body":{"size":0},
  "parts":[
   {"partId":"0","mimeType":"multipart/related","filename":"","headers":[{"name":"Content-Type","value":"multipart/related; boundary=\"rel\"; type=\"multipart/alternative\""}],"body":{"size":0},
    "parts":[
     {"partId":"0.0","mimeType":"multipart/alternative","filename":"","headers":[{"name":"Content-Type","value":"multipart/alternative; boundary=\"alt\""}],"body":{"size":0},
      "parts":[
       {"partId":"0.0.0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\"windows-1252\""}],"body":{"size":17,"data":"R3L832UgliBPdXRsb29rDQo"}},
       {"partId":"0.0.1","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=\"us-ascii\""}],"body":{"size":100,"data":"PGh0bWw-PGJvZHk-PHA-R3ImdXVtbDsmc3psaWc7ZSAmbmRhc2g7IE91dGxvb2s8L3A-PGltZyBzcmM9ImNpZDppbWFnZTAwMS5naWZAMDFEQiI-PC9ib2R5PjwvaHRtbD4NCg"}}]},
     {"partId":"0.1","mimeType":"image/gif","filename":"image001.gif",
      "headers":[{"name":"Content-Type","value":"image/gif; name=\"image001.gif\""},{"name":"Content-Disposition","value":"attachment; filename=\"image001.gif\""},{"name":"Content-ID","value":"<image001.gif@01DB>"}],
      "body":{"size":43,"data":"R0lGODlhAQABAIAAAAAAAP___yH5BAEAAAAALAAAAAABAAEAAAICRAEAOw"}}]},
   {"partId":"1","mimeType":"application/pdf","filename":"Angebot.pdf",
    "headers":[{"name":"Content-Type","value":"application/pdf; name=\"Angebot.pdf\""},{"name":"Content-Disposition","value":"attachment; filename=\"Angebot.pdf\""}],
    "body":{"attachmentId":"ANG-pdf-e1","size":8000}}]}}
```
`messages.get.full.f.json` — (f) `multipart/signed`. plain `Signed hello\r\n` (14), html `<p>Signed hello</p>\r\n` (21)
```json
{"id":"f1","threadId":"f1","labelIds":["INBOX"],"snippet":"Signed hello","historyId":"1106","internalDate":"1757493000000","sizeEstimate":6000,
 "payload":{"partId":"","mimeType":"multipart/signed","filename":"",
  "headers":[{"name":"From","value":"Signer <signer@example.com>"},{"name":"To","value":"user@example.com"},{"name":"Subject","value":"Signed"},{"name":"Message-ID","value":"<f1@example.com>"},
             {"name":"Content-Type","value":"multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=sha-256; boundary=\"sig\""}],
  "body":{"size":0},
  "parts":[
   {"partId":"0","mimeType":"multipart/mixed","filename":"","headers":[{"name":"Content-Type","value":"multipart/mixed; boundary=\"mix\""}],"body":{"size":0},
    "parts":[
     {"partId":"0.0","mimeType":"multipart/alternative","filename":"","headers":[{"name":"Content-Type","value":"multipart/alternative; boundary=\"alt\""}],"body":{"size":0},
      "parts":[
       {"partId":"0.0.0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\"UTF-8\""}],"body":{"size":14,"data":"U2lnbmVkIGhlbGxvDQo"}},
       {"partId":"0.0.1","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=\"UTF-8\""}],"body":{"size":21,"data":"PHA-U2lnbmVkIGhlbGxvPC9wPg0K"}}]}]},
   {"partId":"1","mimeType":"application/pkcs7-signature","filename":"smime.p7s",
    "headers":[{"name":"Content-Type","value":"application/pkcs7-signature; name=\"smime.p7s\""},{"name":"Content-Disposition","value":"attachment; filename=\"smime.p7s\""}],
    "body":{"attachmentId":"ANG-sig-f1","size":3400}}]}}
```
`messages.get.full.g.json` — (g) bounce: `multipart/report` with `message/delivery-status` (inline data, ignored) and `message/rfc822` (attachmentId, no filename → fallback). plain bytes `Delivery to the following recipient failed permanently:\r\n  nobody@example.com\r\n` (79); DSN bytes `Reporting-MTA: dns; mx.example.com\r\n\r\nFinal-Recipient: rfc822; nobody@example.com\r\nAction: failed\r\nStatus: 5.1.1\r\n` (114)
```json
{"id":"g1","threadId":"g1","labelIds":["INBOX","UNREAD"],"snippet":"Delivery to the following recipient failed permanently: nobody@example.com","historyId":"1107","internalDate":"1757494000000","sizeEstimate":7000,
 "payload":{"partId":"","mimeType":"multipart/report","filename":"",
  "headers":[{"name":"From","value":"Mail Delivery Subsystem <mailer-daemon@googlemail.com>"},{"name":"To","value":"user@example.com"},{"name":"Subject","value":"Delivery Status Notification (Failure)"},
             {"name":"Message-ID","value":"<g1@mail.gmail.com>"},{"name":"Content-Type","value":"multipart/report; boundary=\"rep\"; report-type=delivery-status"}],
  "body":{"size":0},
  "parts":[
   {"partId":"0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\"UTF-8\""}],
    "body":{"size":79,"data":"RGVsaXZlcnkgdG8gdGhlIGZvbGxvd2luZyByZWNpcGllbnQgZmFpbGVkIHBlcm1hbmVudGx5Og0KICBub2JvZHlAZXhhbXBsZS5jb20NCg"}},
   {"partId":"1","mimeType":"message/delivery-status","filename":"","headers":[{"name":"Content-Type","value":"message/delivery-status"}],
    "body":{"size":114,"data":"UmVwb3J0aW5nLU1UQTogZG5zOyBteC5leGFtcGxlLmNvbQ0KDQpGaW5hbC1SZWNpcGllbnQ6IHJmYzgyMjsgbm9ib2R5QGV4YW1wbGUuY29tDQpBY3Rpb246IGZhaWxlZA0KU3RhdHVzOiA1LjEuMQ0K"}},
   {"partId":"2","mimeType":"message/rfc822","filename":"","headers":[{"name":"Content-Type","value":"message/rfc822"}],
    "body":{"attachmentId":"ANG-rfc822-g1","size":2200}}]}}
```
`messages.get.full.h.json` — (h) html alternative delivered by `attachmentId` only. plain `See HTML version.\r\n` (19)
```json
{"id":"h1","threadId":"h1","labelIds":["INBOX"],"snippet":"See HTML version.","historyId":"1108","internalDate":"1757495000000","sizeEstimate":260000,
 "payload":{"partId":"","mimeType":"multipart/alternative","filename":"",
  "headers":[{"name":"From","value":"Newsletter <news@example.com>"},{"name":"To","value":"user@example.com"},{"name":"Subject","value":"Big newsletter"},{"name":"Message-ID","value":"<h1@example.com>"}],
  "body":{"size":0},
  "parts":[
   {"partId":"0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\"UTF-8\""}],"body":{"size":19,"data":"U2VlIEhUTUwgdmVyc2lvbi4NCg"}},
   {"partId":"1","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=\"utf-8\""}],"body":{"attachmentId":"ANG-html-h1","size":250000}}]}}
```
`messages.get.full.large-text-attachmentid.json` — bare `text/plain` payload by `attachmentId`
```json
{"id":"L1","threadId":"L1","labelIds":["INBOX"],"snippet":"Lorem ipsum","historyId":"1109","internalDate":"1757496000000","sizeEstimate":910000,
 "payload":{"partId":"","mimeType":"text/plain","filename":"",
  "headers":[{"name":"From","value":"Log Bot <bot@example.com>"},{"name":"To","value":"user@example.com"},{"name":"Subject","value":"Huge log"},{"name":"Message-ID","value":"<L1@example.com>"},
             {"name":"Content-Type","value":"text/plain; charset=\"iso-8859-1\""}],
  "body":{"attachmentId":"ANG-txt-L1","size":900000}}}
```
`threads.get.full.json` — `format=full` thread: message 1 = the `full.a.json` message object verbatim; message 2 = our own reply (plain `Reply body\r\n` (12), html `<div>Reply body</div>\r\n` (23))
```json
{"id":"a1","historyId":"1150","messages":[
 <the "full.a.json" object, unchanged>,
 {"id":"a2","threadId":"a1","labelIds":["SENT"],"snippet":"Reply body","historyId":"1150","internalDate":"1757500000000","sizeEstimate":1500,
  "payload":{"partId":"","mimeType":"multipart/alternative","filename":"",
   "headers":[{"name":"From","value":"Max Mustermann <user@example.com>"},{"name":"To","value":"Alice <alice@example.com>"},{"name":"Subject","value":"Re: Plain hello"},
              {"name":"Date","value":"Thu, 10 Sep 2026 12:26:40 +0200"},{"name":"Message-ID","value":"<a2@example.com>"},{"name":"In-Reply-To","value":"<a1@example.com>"},{"name":"References","value":"<a1@example.com>"}],
   "body":{"size":0},
   "parts":[
    {"partId":"0","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\"UTF-8\""}],"body":{"size":12,"data":"UmVwbHkgYm9keQ0K"}},
    {"partId":"1","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=\"UTF-8\""}],"body":{"size":23,"data":"PGRpdj5SZXBseSBib2R5PC9kaXY-DQo"}}]}}]}
```
(`<the "full.a.json" object, unchanged>` is a placeholder for this document only; the fixture file contains the literal object.)

### 5.7 Fixture contents — batch (`.txt`, LF in git, converted to CRLF by `crlf(_:)`)

`batch.request.sample.txt` — the `[gmail-api §12]` request body; the last line is followed by exactly one newline
```
--batch_minimail_1
Content-Type: application/http
Content-ID: <m1>

GET /gmail/v1/users/me/messages/18f2c1a2b3c4d5e6?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date

--batch_minimail_1
Content-Type: application/http
Content-ID: <m2>

POST /gmail/v1/users/me/messages/18f2c0c0c0c0c0c0/modify
Content-Type: application/json

{"removeLabelIds":["UNREAD"]}

--batch_minimail_1--
```
`batch.response.sample.txt` — the `[gmail-api §12]` response body (outer status/headers excluded)
```
--batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN
Content-Type: application/http
Content-ID: <response-m1>

HTTP/1.1 200 OK
Content-Type: application/json; charset=UTF-8

{"id":"18f2c1a2b3c4d5e6","threadId":"18f2c1a2b3c4d5e6","labelIds":["INBOX"]}
--batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN
Content-Type: application/http
Content-ID: <response-m2>

HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="https://accounts.google.com/"
Content-Type: application/json; charset=UTF-8

{"error":{"code":401,"message":"Invalid Credentials","errors":[{"message":"Invalid Credentials","domain":"global","reason":"authError","location":"Authorization","locationType":"header"}],"status":"UNAUTHENTICATED"}}
--batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN--
```
`batch.response.mixed.txt` — boundary `batch_mixed`; ids out of order; one 204 header-only part
```
--batch_mixed
Content-Type: application/http
Content-ID: <response-m3>

HTTP/1.1 404 Not Found
Content-Type: application/json; charset=UTF-8

{"error":{"code":404,"message":"Requested entity was not found.","errors":[{"message":"Requested entity was not found.","domain":"global","reason":"notFound"}],"status":"NOT_FOUND"}}
--batch_mixed
Content-Type: application/http
Content-ID: <response-m1>

HTTP/1.1 200 OK
Content-Type: application/json; charset=UTF-8

{"id":"a1","threadId":"a1","labelIds":["INBOX"]}
--batch_mixed
Content-Type: application/http
Content-ID: <response-m2>

HTTP/1.1 429 Too Many Requests
Retry-After: 3
Content-Type: application/json; charset=UTF-8

{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","errors":[{"message":"Resource has been exhausted (e.g. check quota).","domain":"global","reason":"rateLimitExceeded"}],"status":"RESOURCE_EXHAUSTED"}}
--batch_mixed
Content-Type: application/http
Content-ID: <response-m4>

HTTP/1.1 204 No Content
Content-Length: 0

--batch_mixed--
```
`batch.response.all-fail.txt` — boundary `batch_fail`; a preamble line before the first delimiter; three 500 parts
```
Preamble that clients must ignore.
--batch_fail
Content-Type: application/http
Content-ID: <response-m1>

HTTP/1.1 500 Internal Server Error
Content-Type: application/json; charset=UTF-8

{"error":{"code":500,"message":"Backend Error","errors":[{"message":"Backend Error","domain":"global","reason":"backendError"}],"status":"INTERNAL"}}
--batch_fail
Content-Type: application/http
Content-ID: <response-m2>

HTTP/1.1 500 Internal Server Error
Content-Type: application/json; charset=UTF-8

{"error":{"code":500,"message":"Backend Error","errors":[{"message":"Backend Error","domain":"global","reason":"backendError"}],"status":"INTERNAL"}}
--batch_fail
Content-Type: application/http
Content-ID: <response-m3>

HTTP/1.1 500 Internal Server Error
Content-Type: application/json; charset=UTF-8

{"error":{"code":500,"message":"Backend Error","errors":[{"message":"Backend Error","domain":"global","reason":"backendError"}],"status":"INTERNAL"}}
--batch_fail--
```

### 5.8 Test support — `Tests/MailCoreTests/Support/GmailFixtures.swift`

```swift
import Foundation
import XCTest
@testable import MailCore

/// Raw bytes of `Fixtures/gmail/<name>`; fails the test (and throws) when the resource is missing.
func gmailFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data
/// `JSONDecoder().decode(T.self, from: gmailFixture(name))`.
func gmailJSON<T: Decodable>(_ name: String, as type: T.Type = T.self, file: StaticString = #filePath, line: UInt = #line) throws -> T
/// Converts every "\n" not already preceded by "\r" into "\r\n" (fixture files are stored with LF).
func crlf(_ data: Data) -> Data
```
`gmailFixture` splits `name` at the last `.` into `forResource`/`withExtension` and calls `Bundle.module.url(forResource:withExtension:subdirectory: "Fixtures/gmail")`.

---

## 6. UI

Not applicable — this module has no screens, views, strings, symbols, haptics or navigation.

---

## 7. Tests

All tests run with `cd Packages/MailCore && swift test` on Linux and macOS (`make core-test`); none need `xcodebuild`. Test classes are `final class … : XCTestCase`, nonisolated. `ParsedAttachment` expectations below are written as tuples `(partId, filename, mimeType, size, contentId, attachmentId, inlineData, charset)`.

| Test file | Test function | Setup | Assertions |
|---|---|---|---|
| `Tests/MailCoreTests/GmailDTOTests.swift` | `testStringUInt64DecodesString` | decode `{"v":"1234567"}` into `struct W: Decodable { var v: StringUInt64 }` | `v.value == 1_234_567` |
| | `testStringUInt64DecodesNumber` | `{"v":1234567}` | `v.value == 1_234_567` |
| | `testStringUInt64DecodesMax` | `{"v":"18446744073709551615"}` | `v.value == UInt64.max` |
| | `testStringUInt64RejectsBadValues` | each of `{"v":""}`, `{"v":"-1"}`, `{"v":"1.0"}`, `{"v":"abc"}`, `{"v":"18446744073709551616"}`, `{"v":true}`, `{"v":null}`, `{"v":1.5}` | `XCTAssertThrowsError` for each; `""`/`"-1"`/`"abc"` throw `DecodingError.dataCorrupted` |
| | `testStringUInt64EncodesAsString` | `JSONEncoder().encode(W(v: 42))` | bytes == `{"v":"42"}` |
| | `testStringUInt64ComparableAndLiteral` | `let a: StringUInt64 = 5; let b = StringUInt64(7)` | `a < b`, `max(a, b) == b`, `a == 5` |
| | `testStringInt64DecodesStringAndNumber` | `{"v":"1757488353000"}` and `{"v":-5}` | `1_757_488_353_000`, `-5`; `{"v":"1e3"}` throws |
| | `testProfileDecodes` | `gmailJSON("profile.json", as: GmailProfile.self)` | `emailAddress == "user@example.com"`, `historyId.value == 1_234_567` |
| | `testLabelsListDecodes` | `labels.list.json` → `GmailListLabelsResponse` | `labels?.count == 5`; `labels![0] == GmailLabel(id: "INBOX", name: "INBOX", type: "system", messageListVisibility: "hide", labelListVisibility: "labelShow")`; `labels![1].messageListVisibility == nil`; `labels![4].type == "user"`, `.name == "Customers/ACME"`, `.color == nil` |
| | `testLabelGetDecodes` | `labels.get.inbox.json`, `labels.get.user.json` → `GmailLabel` | inbox: `threadsUnread == 5`, `color == nil`; user: `color == GmailLabelColor(textColor: "#ffffff", backgroundColor: "#4a86e8")`, `messagesUnread == 3`, `threadsTotal == 44` |
| | `testMessagesListDecodes` | both `messages.list.inbox.*.json` | page 1: `messages == [GmailMessageRef(id:"a1",threadId:"a1"), (b1), (c1)]`, `nextPageToken == "page-2"`, `resultSizeEstimate == 201`; page 2: `messages == nil`, `nextPageToken == nil` |
| | `testHistoryFixturesDecode` | loop over `history.{empty,added,deleted,labels,mixed,added-then-deleted,paged-1,paged-2,own-modify-echo,trash}.json` → `GmailListHistoryResponse` | every file decodes; `empty`: `history == nil`, `historyId == 2000`; `added`: `history![0].messagesAdded![0].message == GmailMessageRef(id:"n1",threadId:"n1",labelIds:["UNREAD","INBOX"])`; `labels`: `history![0].labelsRemoved![0].labelIds == ["UNREAD"]`, `history![0].labelsRemoved![0].message.labelIds == ["INBOX"]`; `own-modify-echo`: `history![1].labelsRemoved![0].message.labelIds == nil`; `paged-1`: `nextPageToken == "hp2"`; `trash`: `history![0].labelsAdded![0].labelIds == ["TRASH"]` and `labelsRemoved![0].labelIds == ["INBOX"]` |
| | `testErrorEnvelopesDecode` | loop over `error.{401,403-rate,403-admin,429,500,400-invalid-history}.json` and `history.404.json` → `GmailErrorEnvelope` | `(error.code, primaryReason, error.status)` == `(401,"required","UNAUTHENTICATED")`, `(403,"userRateLimitExceeded","PERMISSION_DENIED")`, `(403,"insufficientPermissions","PERMISSION_DENIED")`, `(429,"rateLimitExceeded","RESOURCE_EXHAUSTED")`, `(500,"backendError","INTERNAL")`, `(400,"failedPrecondition","FAILED_PRECONDITION")`, `(404,"notFound","NOT_FOUND")`; `error.400`: `error.message!.contains("HistoryId")` |
| | `testErrorEnvelopeRequiresErrorObject` | decode `{"id":"x"}` as `GmailErrorEnvelope` | throws; `{"error":{}}` decodes with `primaryReason == nil` |
| | `testThreadsModifyAndSendResponsesDecode` | `threads.modify.response.json` → `GmailThread`; `send.response.json` → `GmailMessage` | thread: `messages!.count == 2`, `messages![0].labelIds == ["INBOX"]`, `messages![1].payload == nil`; send: `id == "s1"`, `labelIds == ["SENT"]`, `payload == nil` |
| | `testSendAsListDecodes` | `sendas.list.json` | `sendAs!.count == 2`; `[0].isPrimary == true`, `.signature!.hasPrefix("<div dir=\"ltr\">")`; `[1].isPrimary == nil`, `.verificationStatus == "accepted"` |
| | `testAttachmentBodyDecodes` | `attachments.get.png.json` → `GmailPartBody` | `size == 12`; `Base64URL.decode(data!) == Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x46,0x41,0x4B,0x45])` |
| | `testAllFullMessageFixturesDecode` | loop `messages.get.full.{a,b,c,d,e,f,g,h,large-text-attachmentid}.json` → `GmailMessage`; `threads.get.full.json` → `GmailThread` | each decodes; `c.payload!.parts!.count == 3`; `e.payload!.parts![0].parts![0].parts![1].mimeType == "text/html"`; thread `messages!.count == 2` |
| | `testMetadataPayloadWithoutParts` | `messages.get.metadata.plain.json` → `GmailMessage` | `payload!.parts == nil`, `payload!.body == nil`, `payload!.partId == nil`, `payload!.headers!.count == 5`, `sizeEstimate == nil` |
| | `testUnknownKeysIgnored` | decode `{"id":"x","threadId":"x","classificationLabelValues":[{"a":1}],"raw":"AA","payload":{"mimeType":"text/plain","zzz":{"deep":[1,2]}}}` as `GmailMessage` | decodes; `payload!.mimeType == "text/plain"` |
| | `testModifyAndSendRequestEncoding` | `JSONEncoder` with `[.sortedKeys, .withoutEscapingSlashes]` | the four rows of §5.1 byte-exact |
| | `testPartHeaderLookup` | `GmailPart(headers: [("Message-Id","<x@y>"), ("References"," <a@b>\r\n <c@d>\t"), ("Subject","first"), ("subject","second")])` | `header("message-id") == "<x@y>"`, `header("References") == "<a@b> <c@d>"`, `header("SUBJECT") == "first"`, `header("Cc") == nil`; `GmailPart().header("From") == nil` |
| `Tests/MailCoreTests/MessageParserTests.swift` | `testMetadataPlain` | parse `metadata.plain.json` | `id == "m-plain"`, `threadId == "t-plain"`, `historyId == 1001`, `internalDate == 1_757_488_353_000`, `labelIds == ["INBOX","UNREAD"]`, `snippet == "Hi Bob & team, it's done."`, `headers.from == Mailbox(name: "Alice", addr: "alice@example.com")`, `headers.to == [Mailbox(name: nil, addr: "user@example.com")]`, `headers.cc == []`, `headers.replyTo == []`, `headers.subject == "Plain hello"`, `headers.messageID == "<m-plain@example.com>"`, `headers.inReplyTo == nil`, `headers.references == []`, `topMimeType == "text/plain"`, `body == nil`, `attachments == []` |
| | `testMetadataMultipartHeaders` | parse `metadata.multipart.json` | `headers.to == [Mailbox(nil,"user@example.com"), Mailbox("Bob","bob@example.com")]`, `cc == [Mailbox(nil,"carol@example.com")]`, `replyTo == [Mailbox("Alice Support","support@example.com")]`, `subject == "Re: Invoice 42"`, `messageID == "<m-multi@example.com>"` (lower-case `Message-Id` header), `inReplyTo == "<m-plain@example.com>"`, `references == ["<root@example.com>","<m-plain@example.com>"]`, `topMimeType == "multipart/mixed"`, `body == nil` |
| | `testMetadataNonASCII` | parse `metadata.nonascii.json` | `from == Mailbox("Alice Müller","alice@example.com")`, `to == [Mailbox("Müller, Bob","bob@example.com"), Mailbox("Keld Jørn Simonsen","keld@example.com")]`, `subject == "Grüße aus Köln"`, `snippet == "Grüße aus Köln & Umgebung"`, `labelIds == ["INBOX","UNREAD","Label_12"]` |
| | `testMetadataFoldedReferences` | parse `metadata.folded-references.json` | `references == ["<r1@example.com>","<r2@example.com>","<r3@example.com>","<r4@example.com>"]`, `inReplyTo == "<r4@example.com>"`, `subject == "Long subject continued here"` |
| | `testMetadataNoMessageID` | parse `metadata.no-message-id.json` | `labelIds == []`, `snippet == ""`, `subject == ""`, `messageID == nil`, `inReplyTo == nil`, `references == []`, `from == Mailbox(nil,"noreply@example.com")`, `to == []`, `cc == []`, `topMimeType == "text/html"`, `body == nil` |
| | `testThreadIdFallsBackToId` | parse `GmailMessage(id: "solo")` | `threadId == "solo"`, `historyId == 0`, `internalDate == 0`, `labelIds == []`, `snippet == ""`, `headers == ParsedHeaders(from: nil, to: [], cc: [], replyTo: [], subject: "", messageID: nil, inReplyTo: nil, references: [])`, `topMimeType == nil`, `body == nil`, `attachments == []` |
| | `testShapeA_BareTextPlain` | parse `full.a.json` | `body == ParsedBody(html: nil, text: "Hi Bob & team,\nit's done.\n", deferredTextParts: [])`, `attachments == []`, `topMimeType == "text/plain"`, `snippet == "Hi Bob & team, it's done."` |
| | `testShapeB_AlternativeCharsets` | parse `full.b.json` | `body!.text == "Grüße aus Köln\n"` (ISO-8859-1 decoded), `body!.html == "<div dir=\"ltr\">Grüße aus Köln<br><b>Alice</b></div>\n"`, `deferredTextParts == []`, `attachments == []` |
| | `testShapeC_MixedWithAttachments` | parse `full.c.json` | `body!.html == "<div>Invoice attached.</div>\n"`, `body!.text == "Invoice attached.\n"`, `attachments == [("1","invoice-42.pdf","application/pdf",38211,nil,"ANG-pdf-c1",nil,nil), ("2","notes.txt","text/plain",120,nil,"ANG-txt-c1",nil,"utf-8")]`, `deferredTextParts == []`, `topMimeType == "multipart/mixed"`, `headers.cc == [Mailbox(nil,"bob@example.com")]` |
| | `testShapeD_RelatedInlineImage` | parse `full.d.json` | `body!.html!.contains("cid:ii_logo")`, `body!.text == "Logo below\n"`, `attachments == [("1","logo.png","image/png",5120,"ii_logo","ANG-png-d1",nil,nil)]` |
| | `testShapeE_OutlookNested` | parse `full.e.json` | `body!.text == "Grüße – Outlook\n"` (windows-1252: `–` is U+2013), `body!.html!.hasPrefix("<html><body><p>Gr&uuml;")`, `attachments.count == 2`, `attachments[0] == ("0.1","image001.gif","image/gif",43,"image001.gif@01DB",nil,<43 GIF bytes>,nil)`, `attachments[0].inlineData!.count == 43`, `attachments[0].inlineData!.prefix(6) == Data("GIF89a".utf8)`, `attachments[1] == ("1","Angebot.pdf","application/pdf",8000,nil,"ANG-pdf-e1",nil,nil)`, `headers.subject == "AW: Angebot"` |
| | `testShapeF_Signed` | parse `full.f.json` | `body!.html == "<p>Signed hello</p>\n"`, `body!.text == "Signed hello\n"`, `attachments == [("1","smime.p7s","application/pkcs7-signature",3400,nil,"ANG-sig-f1",nil,nil)]` |
| | `testShapeG_Report` | parse `full.g.json` | `body!.text == "Delivery to the following recipient failed permanently:\n  nobody@example.com\n"`, `body!.html == nil`, `attachments == [("2","attachment-2","message/rfc822",2200,nil,"ANG-rfc822-g1",nil,nil)]`, `deferredTextParts == []`, `headers.from == Mailbox("Mail Delivery Subsystem","mailer-daemon@googlemail.com")` |
| | `testShapeH_DeferredHTML` | parse `full.h.json` | `body!.text == "See HTML version.\n"`, `body!.html == nil`, `body!.deferredTextParts == [("1","","text/html",250000,nil,"ANG-html-h1",nil,"utf-8")]`, `attachments == []` |
| | `testLargeTextAttachmentIdBare` | parse `full.large-text-attachmentid.json` | `body != nil`, `body!.text == nil`, `body!.html == nil`, `body!.deferredTextParts == [("","","text/plain",900000,nil,"ANG-txt-L1",nil,"iso-8859-1")]`, `attachments == []`, `topMimeType == "text/plain"` |
| | `testThreadFixtureParsesEveryMessage` | `gmailJSON("threads.get.full.json", as: GmailThread.self).messages!.map(MessageParser.parse)` | `count == 2`; `[0] == MessageParser.parse(gmailJSON("messages.get.full.a.json"))`; `[1].threadId == "a1"`, `[1].labelIds == ["SENT"]`, `[1].headers.inReplyTo == "<a1@example.com>"`, `[1].headers.references == ["<a1@example.com>"]`, `[1].body!.html == "<div>Reply body</div>\n"`, `[1].internalDate == 1_757_500_000_000` |
| | `testEmptyFullBodyIsMetadataOnly` | parse inline `{"id":"z","threadId":"z","payload":{"partId":"","mimeType":"text/plain","filename":"","headers":[],"body":{"size":0}}}` | `body == nil`, `topMimeType == "text/plain"` |
| | `testTopMimeTypeLowercased` | parse inline message with `"mimeType":"Multipart/Mixed"` and one `text/plain` child with data | `topMimeType == "multipart/mixed"` |
| | `testTextAttachmentWithFilenameIsNotBody` | inline `multipart/mixed` with only a `text/plain` part `filename:"a.txt"` with inline data `"aGk"` | `body!.text == nil`, `attachments == [("0","a.txt","text/plain",2,nil,nil,Data("hi".utf8),nil)]` (no Content-Type header → charset nil) |
| | `testInlineImageWithoutFilenameKeepsContentId` | inline part `image/png`, `filename:""`, header `Content-ID: <abc@x>`, data `"iVBORw0KGgpGQUtF"` (no attachmentId) | `attachments == [("1","attachment-1","image/png",12,"abc@x",nil,<12 bytes>,nil)]` |
| | `testRFC2231FilenameFallback` | inline part `application/pdf`, `filename:""`, `Content-Disposition: attachment; filename*=utf-8''%C3%84ngebot.pdf`, `attachmentId:"X"` | `attachments[0].filename == "Ängebot.pdf"` |
| | `testMessageRFC822WithPartsIgnored` | inline `multipart/mixed` [ `text/plain` data `"aGk"`, `message/rfc822` with `parts:[text/html data]` and no attachmentId ] | `body!.text == "hi"`, `body!.html == nil`, `attachments == []` |
| | `testDecodeTextNilWithoutData` | `MessageParser.decodeText(GmailPart(mimeType: "text/plain"))`; `GmailPart(body: GmailPartBody(data: "!!!"))` | both `nil` |
| | `testDecodeTextEmptyData` | `GmailPart(body: GmailPartBody(data: ""))` | `== ""` |
| | `testDecodeTextNormalisesLineEndings` | part with data = base64url of `"a\r\nb\rc\nd"` (`YQ0KYg1jCmQ`) | `== "a\nb\nc\nd"` |
| | `testDecodeTextCharsets` | `decodeText(bytes: Data([0x47,0x72,0xFC,0xDF,0x65]), charset: "ISO-8859-1")`, same bytes with `"x-unknown"`, `Data("Grüße".utf8)` with `nil` | `"Grüße"`, `"Grüße"` (fallback chain), `"Grüße"` |
| | `testSnippetEntityDecoding` | the 8 rows of the §4.4 table through `MessageParser.parse(GmailMessage(id: "s", snippet: row))` | each equals the expected output (trimmed) |
| | `testSnippetTrimmed` | snippet `"  spaced  \n"` | `snippet == "spaced"` |
| | `testSubjectWhitespaceCollapsed` | Subject header `"  A \t\t B  "` | `headers.subject == "A B"` |
| `Tests/MailCoreTests/BatchCodecTests.swift` | `testEncodeMatchesSample` | `BatchCodec.encode([BatchCall(id:"m1",method:"GET",path:"/gmail/v1/users/me/messages/18f2c1a2b3c4d5e6?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date"), BatchCall(id:"m2",method:"POST",path:"/gmail/v1/users/me/messages/18f2c0c0c0c0c0c0/modify",jsonBody:Data("{\"removeLabelIds\":[\"UNREAD\"]}".utf8))], boundary:"batch_minimail_1")` | `== crlf(gmailFixture("batch.request.sample.txt"))` byte-exact; output contains no lone `\n` (every `0x0A` is preceded by `0x0D`) |
| | `testEncodeEmptyCalls` | `encode([], boundary: "b")` | `== Data("--b--\r\n".utf8)` |
| | `testEncodeGetHasNoContentTypeLine` | one GET call | output does not contain `"application/json"`; contains exactly one `"Content-Type: application/http\r\n"` |
| | `testBoundaryFromContentType` | the four inputs of §4.6 | `"batch_abc"`, `"batch_abc"`, `nil`, `nil`; also `"Multipart/Mixed; BOUNDARY=x"` → `"x"` |
| | `testDecodeSample` | `decode(body: crlf(fixture "batch.response.sample.txt"), boundary: "batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN")` | `count == 2`; `[0].id == "m1"`, `[0].status == 200`, `[0].body == Data("{\"id\":\"18f2c1a2b3c4d5e6\",\"threadId\":\"18f2c1a2b3c4d5e6\",\"labelIds\":[\"INBOX\"]}".utf8)`; `[1].id == "m2"`, `[1].status == 401`; `JSONDecoder().decode(GmailErrorEnvelope.self, from: [1].body).primaryReason == "authError"` |
| | `testDecodeMixedOutOfOrder` | `mixed` fixture, boundary `batch_mixed` | `map(\.id) == ["m3","m1","m2","m4"]`, `map(\.status) == [404,200,429,204]`, `[3].body.isEmpty`, `JSONDecoder().decode(GmailMessage.self, from: [1].body).id == "a1"`, `[2].body` decodes to envelope with `primaryReason == "rateLimitExceeded"` |
| | `testDecodeAllFailWithPreamble` | `all-fail` fixture, boundary `batch_fail` | `count == 3`, all `status == 500`, ids `["m1","m2","m3"]` |
| | `testDecodeFewerPartsThanRequested` | `sample` fixture truncated to its first part + close delimiter (build the string in the test) | `count == 1`, `[0].id == "m1"` |
| | `testDecodeContentIDWithoutResponsePrefix` | inline body with `Content-ID: <m9>` | `[0].id == "m9"` |
| | `testDecodeGarbage` | `decode(body: Data("<html>Not Found</html>".utf8), boundary: "b")`; empty `Data()`; LF-only version of the sample (`gmailFixture` without `crlf`) | each throws `BatchCodecError.noDelimiter` |
| | `testDecodeTruncated` | sample with the close delimiter removed | throws `.truncated` |
| | `testDecodeNoParts` | `Data("--b--\r\n".utf8)` | throws `.noParts` |
| | `testDecodeMissingContentID` | one part whose outer headers are only `Content-Type: application/http` | throws `.missingContentID(index: 0)` |
| | `testDecodeBadStatusLine` | one part whose inner first line is `{"id":"x"}` | throws `.badStatusLine(index: 0)` |
| | `testDecodeMalformedPart` | one part without the blank line between outer headers and inner message: `--b\r\nContent-ID: <m1>\r\nHTTP/1.1 200 OK\r\n--b--\r\n` | throws `.malformedPart(index: 0)` |
| | `testDecodeLargeBodyPerformance` | 25 parts each with a 200 KB JSON body (built in the test) | `measure { }` block; decodes 25 parts; wall time is recorded only (no assertion on ms — CI has no perf gate) |

Test totals: `GmailDTOTests` 22, `MessageParserTests` 29, `BatchCodecTests` 16 → 67 functions.

---

## 8. Tasks

Ordered; each is one sitting (≈ 50–300 lines). All verification runs on Linux (`swift test`) or macOS.

- [ ] **T03.1 DTOs and string-number wrappers** — files: `Packages/MailCore/Sources/MailCore/Gmail/GmailDTO.swift`. Done when every type of §3.1 compiles in Swift 6 language mode with zero warnings about `Sendable`, `StringUInt64`/`StringInt64` implement §4.1, `GmailPart.header` implements §4.2 (imports `HeaderFolding` from 02). Verify: `cd Packages/MailCore && swift build 2>&1 | grep -E "error|warning: .*Sendable" ; echo exit=$?` prints only `exit=1` (no matches).
- [ ] **T03.2 DTO fixtures + test support** — files: `Tests/MailCoreTests/Support/GmailFixtures.swift`, the 28 fixtures of §5.2–§5.4 (`profile`, `labels.*`, `messages.list.*`, `attachments.get.*`, `threads.modify.response`, `send.response`, `sendas.list`, `history.*` incl. `404`, `error.*`). Done when every file is valid JSON and loads through `Bundle.module`. Verify: `cd Packages/MailCore && for f in Tests/MailCoreTests/Fixtures/gmail/*.json; do python3 -m json.tool "$f" >/dev/null || echo "BAD $f"; done; ls Tests/MailCoreTests/Fixtures/gmail | wc -l` prints no `BAD` lines and `28`.
- [ ] **T03.3 GmailDTOTests** — files: `Tests/MailCoreTests/GmailDTOTests.swift`. Done when the 22 tests of §7 pass. Verify: `cd Packages/MailCore && swift test --filter GmailDTOTests 2>&1 | tail -3` shows `Executed 22 tests, with 0 failures`.
- [ ] **T03.4 Message fixtures** — files: the 15 fixtures of §5.5–§5.6 (`messages.get.metadata.*` ×5, `messages.get.full.*` ×9, `threads.get.full.json`). Done when each decodes as `GmailMessage`/`GmailThread` (the loop tests `testAllFullMessageFixturesDecode` and `testMetadataPayloadWithoutParts` from T03.3 are extended to cover them) and the `data`/`size` values match §5.6 byte for byte. Verify: `cd Packages/MailCore && swift test --filter GmailDTOTests/testAllFullMessageFixturesDecode` passes, and this self-consistency check (every inline `data` decodes to exactly `size` bytes) prints `sizes ok`:
  ```
  cd Packages/MailCore && python3 - <<'EOF'
  import base64, glob, json
  def walk(p, f):
      b = p.get("body", {})
      if b.get("data") is not None:
          raw = base64.urlsafe_b64decode(b["data"] + "=" * (-len(b["data"]) % 4))
          assert b.get("size") == len(raw), (f, p.get("partId"), b.get("size"), len(raw))
      for c in p.get("parts", []): walk(c, f)
  files = glob.glob("Tests/MailCoreTests/Fixtures/gmail/messages.get.full.*.json") + ["Tests/MailCoreTests/Fixtures/gmail/threads.get.full.json"]
  for f in files:
      d = json.load(open(f))
      for m in d.get("messages", [d]): walk(m["payload"], f)
  print("sizes ok")
  EOF
  ```
- [ ] **T03.5 MessageParser — identity, headers, metadata, snippet** — files: `Sources/MailCore/Gmail/MessageParser.swift` (types of §3.2, `parse` steps 1–3 of §4.3, `SnippetEntities` §4.4; `collect` stubbed to return an empty context), `Tests/MailCoreTests/MessageParserTests.swift` (the 7 metadata/identity tests, `testSnippetEntityDecoding`, `testSnippetTrimmed`, `testSubjectWhitespaceCollapsed`). Done when those 10 tests pass. Verify: `cd Packages/MailCore && swift test --filter MessageParserTests/testMetadata` and `--filter MessageParserTests/testSnippet` pass.
- [ ] **T03.6 MessageParser — tree walk and text decoding** — files: `MessageParser.swift` (§4.3.1 `collect`, §4.3.2 `decodeText` both overloads, `fallbackFilename`, `stripAngleBrackets`, `normalizeLineEndings`), `MessageParserTests.swift` (the remaining 19 tests). Done when all 29 `MessageParserTests` pass. Verify: `cd Packages/MailCore && swift test --filter MessageParserTests 2>&1 | tail -3` shows `Executed 29 tests, with 0 failures`.
- [ ] **T03.7 BatchCodec encode + boundary + request fixture** — files: `Sources/MailCore/Gmail/BatchCodec.swift` (`BatchCall`, `BatchPartResponse`, `BatchCodecError`, `encode`, `boundary(fromContentType:)`, `decode` stubbed to throw `.noDelimiter`), `Tests/MailCoreTests/Fixtures/gmail/batch.request.sample.txt`, `Tests/MailCoreTests/BatchCodecTests.swift` (encode + boundary tests). Done when `testEncodeMatchesSample`, `testEncodeEmptyCalls`, `testEncodeGetHasNoContentTypeLine`, `testBoundaryFromContentType` pass. Verify: `cd Packages/MailCore && swift test --filter BatchCodecTests/testEncode && swift test --filter BatchCodecTests/testBoundary`.
- [ ] **T03.8 BatchCodec decode + response fixtures** — files: `BatchCodec.swift` (§4.7), `batch.response.{sample,mixed,all-fail}.txt`, `BatchCodecTests.swift` (the 12 decode tests). Done when all 16 `BatchCodecTests` pass. Verify: `cd Packages/MailCore && swift test --filter BatchCodecTests 2>&1 | tail -3` shows `Executed 16 tests, with 0 failures`.
- [ ] **T03.9 Format, lint, full run** — files: any of the above (formatting only). Done when `make format` yields no diff on a second run, `make lint` exits 0 (no forbidden imports in `Sources/MailCore`; the three new files import only `Foundation`), and the whole package test suite passes on Linux. Verify: `make format && git diff --stat -- Packages/MailCore && make lint && make core-test` (or `make core-test-nohtml` if SwiftSoup does not build on Linux — the 67 tests of this module are in `MailCoreTests` and run either way).

---

## 9. Acceptance criteria

1. `grep -rhE "^import " Packages/MailCore/Sources/MailCore/Gmail/*.swift | sort -u` prints exactly `import Foundation`.
2. Every signature of architecture §2.2 "Gmail" section exists with identical names, access levels and types; the only additions are those listed in §10 D1–D5. Verify: `grep -cE "public (struct|enum|let|static func|func) (StringUInt64|StringInt64|GmailProfile|GmailLabelColor|GmailLabel|GmailListLabelsResponse|GmailHeader|GmailPartBody|GmailPart|GmailMessage|GmailThread|GmailMessageRef|GmailListMessagesResponse|GmailHistoryMessageChange|GmailHistoryLabelChange|GmailHistory|GmailListHistoryResponse|GmailSendAs|GmailListSendAsResponse|GmailModifyRequest|GmailSendRequest|GmailErrorEnvelope|GmailFormat|gmailMetadataHeaders|ParsedHeaders|ParsedAttachment|ParsedBody|ParsedMessage|MessageParser|BatchCall|BatchPartResponse|BatchCodec)\b" Packages/MailCore/Sources/MailCore/Gmail/*.swift | awk -F: '{s+=$2} END {print s}'` prints `32`.
3. `cd Packages/MailCore && swift test --filter "GmailDTOTests|MessageParserTests|BatchCodecTests"` reports `Executed 67 tests, with 0 failures` on Linux (Swift 6.1+) and on macOS (Xcode 26.6).
4. `BatchCodec.encode` of the two-call sample equals `[gmail-api §12]`'s request body byte for byte (test `testEncodeMatchesSample`); the encoded output contains no `0x0A` that is not preceded by `0x0D`.
5. `BatchCodec.decode` of `[gmail-api §12]`'s response sample yields ids `m1` (200) and `m2` (401) with the JSON bodies intact (test `testDecodeSample`), and matching never depends on part order (test `testDecodeMixedOutOfOrder`).
6. `MessageParser.parse` produces the exact `ParsedMessage` values of §7 for shapes (a)–(h), the deferred-text fixture, and the five metadata fixtures; ISO-8859-1 and windows-1252 parts decode to the correct Unicode strings; snippets are entity-decoded.
7. `MessageParser.parse` never throws and never traps on any decoded `GmailMessage` — verified by the metadata/minimal/empty-payload tests (`testThreadIdFallsBackToId`, `testEmptyFullBodyIsMetadataOnly`, `testMetadataNoMessageID`).
8. The 47 fixture files of §2 exist under `Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/`, every `.json` passes `python3 -m json.tool`, every `.txt` is LF-only in git (`file Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail/batch.*.txt` reports no `CRLF`), and `Bundle.module` resolves each (test loops). Verify: `ls Packages/MailCore/Tests/MailCoreTests/Fixtures/gmail | wc -l` prints `47`.
9. `make lint` passes (swift-format strict; package boundary grep finds nothing under `Sources/MailCore`).
10. The `ios` CI job (`make core-test` on macOS) passes the same 67 tests — the fixtures are also copied into the app test bundle by `project.yml` (`Packages/MailCore/Tests/MailCoreTests/Fixtures` folder reference) without duplicates, so module 14's `FixtureLoader` can read `gmail/*.json` from `Bundle(for:)` of `minimailTests`.

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / resolution chosen |
|---|---|---|---|
| D1 | `Equatable` on every DTO | DEVIATION (additive) | Added so tests can compare decoded values and module 05 can compare `Result<GmailMessage, GmailError>` payloads. No wire effect. |
| D2 | Public memberwise initialisers with defaults on DTOs; `Hashable`, `ExpressibleByIntegerLiteral`, `init(_:)` on `StringUInt64`/`StringInt64` | DEVIATION (additive) | Architecture lists stored properties only; without public inits no other module could construct fixtures/stubs. Defaults follow "everything optional except ids". |
| D3 | `ParsedAttachment.charset: String?` | DEVIATION (additive) | Architecture §4.5 `prepareBody` says "decode with part charset" for deferred text parts, but §2.2 `ParsedAttachment` carries no charset. Added with default `nil`; module 06 does not store it (no `attachment.charset` column) and module 07 reads it. |
| D4 | `MessageParser.decodeText(bytes:charset:)` | DEVIATION (additive) | The bytes of a deferred text part arrive via `attachments.get` as `Data`; the `GmailPart` overload cannot be used. Same charset chain and line-ending normalisation. |
| D5 | `BatchCodecError` enum | DEVIATION (additive) | Architecture's `decode(...) throws` names no error type. Module 05 maps every case to `GmailError.batchMalformed`; cases exist for tests and logs. |
| A1 | Gmail delivers `body.data` already CTE-decoded (no quoted-printable/base64 step after base64url) | GWS-CLI-verified behaviour, not documented prose (`[mime-rfc §5.1]`, `[gmail-api gotcha 13]`) | Parser performs no CTE decoding. If a real message shows QP artefacts (`=3D`, `=C3=BC`) in `ParsedBody.text`, module 07 logs `sync.parse.cte-suspect` and the fix is a one-line `QuotedPrintable.decode` call in `decodeText` — nothing else changes. Device checklist item for module 14. |
| A2 | Shape of `payload` for `format=metadata` without a `fields` mask (`body: {size: 0}`, `partId: ""`, `filename: ""`) | UNVERIFIED (`[gmail-api §3]`) | Step 3 of §4.3 classifies any payload with no `parts`, no `body.data` and no `body.attachmentId` as metadata-only, so both the masked and unmasked shapes yield `body == nil`. |
| A3 | Whether `message.labelIds` is always populated inside history change records | UNVERIFIED (`[gmail-api §13]`, architecture §14 #8) | DTO keeps `labelIds` optional; fixture `history.own-modify-echo.json` record 2031 exercises the absent case for module 07's reducer. |
| A4 | `message/rfc822` attachments expanded by Gmail into `parts` (no `attachmentId`) | UNVERIFIED shape | Ignored by rule (f) in §4.3.1 so an attached mail's text never masquerades as the outer body. If real messages show forwarded `.eml` attachments missing from the attachment list, add a rule: `message/rfc822` with `parts` → synthesise an attachment with `filename "forwarded-message.eml"` and `attachmentId nil` (not downloadable in stage 1). Open for module 14's device checklist. |
| A5 | First-alternative-wins vs RFC 2046 "last alternative" | design choice | First `text/html`/`text/plain` in tree order (Google's own CLI does the same, `[mime-rfc §5.2]`). |
| A6 | `In-Reply-To` with several msg-ids | design choice | First token after `MessageIDs.split` is used (`[mime-rfc §1.4]`: the parent's `Message-ID` comes first in practice); the rest is discarded because `MessageIDs.referencesChain` takes one parent id. |
| A7 | `Content-ID` values that are not angle-bracketed, or contain `%`-encoding | `[mime-rfc §5.4]`, RFC 2392 | Stored verbatim after bracket stripping, not percent-decoded; module 08 percent-decodes the `cid:` URL side before comparing with `referencedContentIDs`. |
| A8 | Fallback attachment filename `attachment-<partId>` (no extension) | design choice | QuickLook (module 10) chooses the previewer by content sniffing/UTType from `mimeType`, so a missing extension is acceptable; Gmail supplies a filename for virtually every real attachment. |
| A9 | Batch parts carry no `Content-Length` / `Content-Transfer-Encoding: binary` | probe-verified sample (`[gmail-api §12]`) | Encoder emits exactly the probe sample. If Google ever rejects a part with a JSON body, add `Content-Length: <bytes>` after the inner `Content-Type` line (module 05 owns the retry, module 03 the byte format; `testEncodeMatchesSample` would be updated together with the fixture). |
| A10 | Per-part `Retry-After` headers inside a batch | not surfaced | `BatchPartResponse` carries no headers; architecture §6.3 retries rate-limited parts with `Backoff.transient`, so the per-part header is not needed. Adding `headers: [(String, String)]` later is additive. |
| A11 | `Base64URL.decode` accepts both alphabets and unpadded input | module 02 contract (`[mime-rfc §8.3]`) | Relied upon; `testDecodeTextNilWithoutData` covers the rejection path (`"!!!"`). |
| A12 | `HeaderFolding.unfold` keeps the folding WSP (RFC 5322 §2.2.3) | module 02 contract | `testMetadataFoldedReferences` expects `"Long subject continued here"`; if module 02 collapses differently, `collapseWhitespace` in §4.3 step 2 still yields the same result. |
| A13 | JSON fixtures contain raw UTF-8 (`Grüße`, `–`) and `\r\n` escapes | assumed fine for `JSONDecoder` on Linux Foundation | Standard JSON; `swift-corelibs-foundation` decodes both. |
| A14 | `[mime-rfc §5.2]` `ctx.inline[cid]` map | intentionally not implemented | Inline-vs-attachment is decided by module 08 from the sanitized HTML's `referencedContentIDs` (architecture §4.5), so the parser only records `contentId`. |
| A15 | Attachment ids are unstable across `messages.get` calls | UNVERIFIED (`[gmail-api §6]`, architecture §14 #13) | `ParsedAttachment.attachmentId` is documented transient; the re-resolve path (modules 08/10, 07 §7.6) re-parses a fresh `GmailMessage` and matches by `partId`. |
