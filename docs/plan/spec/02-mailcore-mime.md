# Module 02 — `mailcore-mime`: MailCore encodings, headers, MIME builder, compose assembly

Source of truth: `docs/plan/design/architecture.md` §0 (decisions 1, 8, 13), §1.3, §1.5, §1.6, §2.1–§2.2, §7.1–§7.5, §13.2, §15 (D17, D24), Appendix A; `docs/plan/design/modules.md` (scope paragraph "02-mailcore-mime"); research `docs/plan/research/mime-rfc.md` (cited `[mime-rfc §n]`), `docs/plan/research/html-rendering.md` §5 (cited `[html-rendering §n]`), `docs/plan/research/gmail-api.md` §14 (cited `[gmail-api §n]`). Depends on module `01-project-setup` (package skeleton only). Every fact below that the research marks UNVERIFIED is marked UNVERIFIED here too (§10).

Conventions used in this document: `CRLF` = the two bytes `0x0D 0x0A`; `SP` = `0x20`; `U+202F` = NARROW NO-BREAK SPACE (UTF-8 `E2 80 AF`); "ASCII" = every unicode scalar ≤ `0x7F`; "WSP" = SP or TAB. Line numbers `mime-rfc.md:379` refer to the research file as committed (`git show 4f089cf:docs/plan/research/mime-rfc.md` prints the same text).

---

## 1. Purpose & scope

**In scope (all under `Packages/MailCore/Sources/MailCore/`, Foundation only, nonisolated, no regular expressions, no third-party code):**

| Area | Files | What it delivers |
|---|---|---|
| Encodings | `Encoding/Base64URL.swift`, `Encoding/QuotedPrintable.swift`, `Encoding/RFC2047.swift`, `Encoding/RFC2231.swift`, `Encoding/Charsets.swift` | base64url (padded out, tolerant in), quoted-printable (76-col, uppercase hex), RFC 2047 encoded-words (decode B/Q, encode B), RFC 2231 parameters (decode continuations + charset, encode `filename*`), IANA charset → `String.Encoding` table with a never-failing decode chain |
| Headers | `Headers/Mailbox.swift`, `Headers/AddressParser.swift`, `Headers/HeaderDate.swift`, `Headers/HeaderFolding.swift`, `Headers/ContentTypeParams.swift`, `Headers/MessageIDs.swift` | mailbox struct + RFC 5322 serializer, RFC 5322 §3.4 address-list tokenizer, RFC 5322 date format/parse + Gmail attribution date, header unfold/fold, `Content-Type`/`Content-Disposition` parameter tokenizer, `Message-ID`/`References` helpers incl. the RFC 5322 §3.6.4 chain |
| MIME | `MIME/OutgoingMessage.swift`, `MIME/MIMEBuilder.swift` | outgoing message value types, boundary generator, byte-exact RFC 5322/2045/2046 builder for structures A (`multipart/alternative`) and B (`multipart/mixed` ⊃ A + attachments) |
| Compose | `Compose/ComposeStyle.swift`, `Compose/ReplyAll.swift`, `Compose/SubjectPrefix.swift`, `Compose/Quoting.swift`, `Compose/OutgoingBodies.swift`, `Compose/PlainTextHTML.swift` | default font/size/colour model, reply-all recipient algorithm (§7.1), `Re:`/`Fwd:` rules, Gmail-convention quote/forward blocks (HTML + text), typed text + style + signature + quote → HTML/text bodies, plain-text → HTML conversion (escape + linkify) |
| Tests | `Packages/MailCore/Tests/MailCoreTests/*Tests.swift` (one per source file), `Tests/MailCoreTests/Support/Fixtures.swift`, `Tests/MailCoreTests/Fixtures/mime/*`, `Tests/MailCoreTests/Fixtures/vectors/*.json` | table-driven XCTest cases from `[mime-rfc §8]`, byte-exact MIME pins from `[mime-rfc §7]` |

**Explicitly out of scope (owned elsewhere):** Gmail DTOs, `MessageParser`, `BatchCodec` (module 03 — it *consumes* `Base64URL`, `Charsets`, `RFC2047`, `RFC2231`, `AddressParser`, `HeaderFolding`, `ContentTypeParams`, `MessageIDs`, `HeaderDate`); anything importing SwiftSoup, `QuoteExtractor`, `Sanitizer`, `SignatureSanitizer` (module 08); `ThreadDocument` (module 08); sync/outbox actors and the network send path (module 07 — it consumes `MIMEBuilder`, `OutgoingMessage`, `Quoting`, `OutgoingBodies`, `Base64URL.encode`, `SelfIdentity`, `ComposeStyle`); `ComposeScreen`/`ComposeModel`, `SendJob`, `ForwardAttachmentRef` (module 11 — it consumes `ReplyAll`, `SubjectPrefix`, `MessageIDs`, `AddressParser`, `QuoteSource`, `ComposeMode`, `Quoting.textFromHTML`); `Settings`/`SettingsStore` (module 01 — `Settings.composeStyle` is a `ComposeStyle` from this module); the settings UI (module 13); `LabelAlgebra`, `ThreadAggregator`, `DayBoundary` (module 06); the thread-view subject title uses `SubjectPrefix.stripForDisplay` (module 10) and `ThreadAggregator` uses it for `thread.subject` (module 06).

**Consumers of this module:** 03-mailcore-gmail-model, 06-storage (`SubjectPrefix.stripForDisplay`, `Mailbox`), 07-sync-outbox, 08-html-rendering (`PlainTextHTML.convert` inside `Sanitizer.fromPlainText`, `OutgoingBodies.escape`), 10-thread-view, 11-compose, 13-settings-theme-signature (`ComposeStyle.Family.displayName`, clamping), 14-qa.

**Non-negotiable rules for this module** (from architecture §1.5, §2.1, `make lint`):
1. `import Foundation` only. Never `CoreFoundation`, `UIKit`, `SwiftUI`, `GRDB`, `AppAuth`, `WebKit`, `Security`, `SwiftSoup`, `CryptoKit`, `RegexBuilder`.
2. No `Regex` literals and no `NSRegularExpression` anywhere in this module — every scanner is hand-written over `[UInt8]` / `String.UnicodeScalarView` so Linux and Darwin behave identically.
3. Every public type is `Sendable`; every function is a pure `static func`; nothing is `@MainActor`; nothing keeps mutable global state (`DateFormatter` instances are created per call and never shared).
4. Nothing in this module throws. Every function is total: bad input yields `nil`, an empty value, or the documented fallback.
5. `swift format lint --strict` must pass (`.swift-format` from module 01: 4-space indent, line length 120, `NeverForceUnwrap`, `OrderedImports`, `AlwaysUseLowerCamelCase`). Use `String(decoding:as:)` or `?? ""` instead of `!`.

---

## 2. Files

All paths relative to the repo root. `new` = created by this module; nothing in this module modifies a file owned by another module.

| Path | Kind | Purpose |
|---|---|---|
| `Packages/MailCore/Sources/MailCore/Encoding/Base64URL.swift` | new | `enum Base64URL` — RFC 4648 §5 encode (padded, single line) / tolerant decode |
| `Packages/MailCore/Sources/MailCore/Encoding/QuotedPrintable.swift` | new | `enum QuotedPrintable` — RFC 2045 §6.7 encoder (76 cols, uppercase hex, trailing WSP encoded) and tolerant decoder |
| `Packages/MailCore/Sources/MailCore/Encoding/RFC2047.swift` | new | `enum RFC2047` — encoded-word decode (B and Q, adjacent-word joining) and B-word encode with folding |
| `Packages/MailCore/Sources/MailCore/Encoding/RFC2231.swift` | new | `enum RFC2231` — parameter continuations + `charset'lang'%xx` decode; `filename` / `filename*` encoder |
| `Packages/MailCore/Sources/MailCore/Encoding/Charsets.swift` | new | `enum Charsets` — IANA name (+ aliases, `*lang` stripped) → `String.Encoding`; never-failing decode chain |
| `Packages/MailCore/Sources/MailCore/Headers/Mailbox.swift` | new | `struct Mailbox` — name/addr, `key`, `displayName`, RFC 5322 `serialized()` |
| `Packages/MailCore/Sources/MailCore/Headers/AddressParser.swift` | new | `enum AddressParser` — RFC 5322 §3.4 tokenizer (quoted-string, nested comments, groups, obs-route, legacy `addr (Name)`) |
| `Packages/MailCore/Sources/MailCore/Headers/HeaderDate.swift` | new | `enum HeaderDate` — RFC 5322 §3.3 format, tolerant parse, Gmail attribution format with U+202F |
| `Packages/MailCore/Sources/MailCore/Headers/HeaderFolding.swift` | new | `enum HeaderFolding` — unfold; fold address lists and message-id lists at ≤ 78 |
| `Packages/MailCore/Sources/MailCore/Headers/ContentTypeParams.swift` | new | `struct ContentTypeValue`, `enum ContentTypeParams` — `type; name=value` tokenizer |
| `Packages/MailCore/Sources/MailCore/Headers/MessageIDs.swift` | new | `enum MessageIDs` — split, normalize, generate, RFC 5322 §3.6.4 `References` chain |
| `Packages/MailCore/Sources/MailCore/MIME/OutgoingMessage.swift` | new | `struct OutgoingAttachment`, `struct OutgoingMessage`, `struct BoundaryGenerator` |
| `Packages/MailCore/Sources/MailCore/MIME/MIMEBuilder.swift` | new | `enum MIMEBuilder.build` — byte-exact RFC 5322 + MIME serializer (structures A and B) |
| `Packages/MailCore/Sources/MailCore/Compose/ComposeStyle.swift` | new | `struct ComposeStyle` + `Family` (font stacks of `[html-rendering §5.3]`), clamping, hex validation, `inlineCSS` |
| `Packages/MailCore/Sources/MailCore/Compose/ReplyAll.swift` | new | `struct SelfIdentity`, `struct Recipients`, `enum ReplyAll.recipients` (architecture §7.1) |
| `Packages/MailCore/Sources/MailCore/Compose/SubjectPrefix.swift` | new | `enum SubjectPrefix` — `reply`, `forward`, `stripForDisplay` |
| `Packages/MailCore/Sources/MailCore/Compose/Quoting.swift` | new | `enum ComposeMode`, `struct QuoteSource`, `enum Quoting` — attribution, `gmail_quote` reply block, forward banner, text quoting, `textFromHTML` |
| `Packages/MailCore/Sources/MailCore/Compose/OutgoingBodies.swift` | new | `enum OutgoingBodies` — `escape`, `html`, `document`, `text` |
| `Packages/MailCore/Sources/MailCore/Compose/PlainTextHTML.swift` | new | `enum PlainTextHTML.convert` — escape + linkify + `<div>` per line in `<div class="mm-plaintext">` |
| `Packages/MailCore/Tests/MailCoreTests/Support/Fixtures.swift` | new | `enum Fixture` — loads `Bundle.module` fixtures as `Data`/`String`/decoded JSON (shared with modules 03, 06, 08) |
| `Packages/MailCore/Tests/MailCoreTests/Base64URLTests.swift` | new | vectors `[mime-rfc §8.3]`, padding, both alphabets, rejection |
| `Packages/MailCore/Tests/MailCoreTests/QuotedPrintableTests.swift` | new | 7 encode rows, decode tolerance, round trip |
| `Packages/MailCore/Tests/MailCoreTests/RFC2047Tests.swift` | new | 9 decode rows, encode passthrough/chunking/folding, round trips |
| `Packages/MailCore/Tests/MailCoreTests/RFC2231Tests.swift` | new | 6 filename rows, encoder for `Ängebot.pdf`, ASCII passthrough |
| `Packages/MailCore/Tests/MailCoreTests/CharsetsTests.swift` | new | alias table, `*lang`, quotes, fallback chain, BOM |
| `Packages/MailCore/Tests/MailCoreTests/MailboxTests.swift` | new | `key`, `displayName`, serializer (bare / plain / quoted / encoded) |
| `Packages/MailCore/Tests/MailCoreTests/AddressParserTests.swift` | new | `[mime-rfc §8.4]` table + groups, obs-route, obs-addr-list, folded, `parseFirst` |
| `Packages/MailCore/Tests/MailCoreTests/HeaderDateTests.swift` | new | format Europe/Berlin + UTC, attribution U+202F, tolerant parse matrix |
| `Packages/MailCore/Tests/MailCoreTests/HeaderFoldingTests.swift` | new | unfold, fold at 78 after commas, message-id continuation |
| `Packages/MailCore/Tests/MailCoreTests/ContentTypeParamsTests.swift` | new | quoted/unquoted params, case, `boundary`, `charset` |
| `Packages/MailCore/Tests/MailCoreTests/MessageIDsTests.swift` | new | split, normalize, generate, chain cases of RFC 5322 §3.6.4 |
| `Packages/MailCore/Tests/MailCoreTests/MIMEBuilderTests.swift` | new | byte-exact reply / forward / Gmail-web forward; structural checks |
| `Packages/MailCore/Tests/MailCoreTests/ComposeStyleTests.swift` | new | defaults, clamp, hex validation, Codable leniency, `inlineCSS` |
| `Packages/MailCore/Tests/MailCoreTests/ReplyAllTests.swift` | new | 16 rows of `[mime-rfc §8.1]` |
| `Packages/MailCore/Tests/MailCoreTests/SubjectPrefixTests.swift` | new | `[mime-rfc §8.2]` + `stripForDisplay` |
| `Packages/MailCore/Tests/MailCoreTests/QuotingTests.swift` | new | attribution, reply skeleton, `> `/`>`, forward banner, Cc omission, `textFromHTML` |
| `Packages/MailCore/Tests/MailCoreTests/OutgoingBodiesTests.swift` | new | wrapper, per-line divs, escaping, signature block, quote outside, document, text layout |
| `Packages/MailCore/Tests/MailCoreTests/PlainTextHTMLTests.swift` | new | escape, linkify, trailing punctuation, `www.`, empty lines |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/reply-all.eml` | new | 2276 CRLF bytes of `[mime-rfc §7.1]` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/reply-all.sha256` | new | `b9f8078c1d50352b00f1486624bb2247ec19587ccf388b652aed62da0d1fcbd3` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/reply-all.raw.txt` | new | 3035-char unpadded base64url of the reply (`mime-rfc.md:441`) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/forward-pdf.eml` | new | 2927 CRLF bytes of `[mime-rfc §7.2]` (no `In-Reply-To`) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/forward-pdf.sha256` | new | `2127dc5426a76d3deb405f04f30b602d22461af3b8ea6dbdee8d494d66429261` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/forward-pdf.raw.txt` | new | 3903-char unpadded base64url of the forward (`mime-rfc.md:521`) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/forward-pdf-gmailweb.eml` | new | 2971 CRLF bytes: §7.2 with `In-Reply-To:` inserted after `Message-ID:` (`[mime-rfc §7.3]`) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/forward-pdf-gmailweb.sha256` | new | `d8dc2b8522a8354d8cb0709757660d1ddea87f342d75a23752bb619cf9e74d86` (derived in §5.1; re-verified by the test) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/stub.pdf` | new | the 125-byte PDF stub of `[mime-rfc §7.2]` |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/.gitattributes` | new | `*.eml -text`, `*.raw.txt -text`, `*.pdf binary` — keeps the CRLF fixtures byte-exact in git |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/qp.json` | new | quoted-printable rows |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/rfc2047.json` | new | encoded-word decode rows |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/base64.json` | new | base64 / base64url rows |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/rfc2231.json` | new | filename parameter rows |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/addresses.json` | new | address-list parse rows |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/reply-all.json` | new | 16 reply-all rows |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/subject.json` | new | subject prefix rows |

Files of module 01 this module relies on but does not touch: `Packages/MailCore/Package.swift` (targets `MailCore`, `MailCoreTests` with `resources: [.copy("Fixtures")]`, language mode 6, platforms iOS 17 / macOS 14), `Makefile` (`core-test`, `lint`, `format`), `.swift-format`.

---

## 3. Public interface

Every declaration below is `public` unless marked `internal`. Signatures are copied verbatim from architecture §2.2; additions (extra initialisers and helpers that the architecture leaves implicit) are marked `// ADDITION`; there are no deviations except the ones marked `DEVIATION:` (all are implementation-forced, none change a call site).

### 3.1 `Encoding/Base64URL.swift`

```swift
import Foundation

/// RFC 4648 §5 "URL and Filename safe" base64. [mime-rfc §1.2]
public enum Base64URL {
    /// Encodes `data` as ONE line (no CRLF) using the `-`/`_` alphabet WITH `=` padding
    /// (Google's own sample keeps the padding). Empty data → "".
    public static func encode(_ data: Data) -> String

    /// Decodes padded or unpadded input in EITHER alphabet (`+/` or `-_`).
    /// Returns nil when the string contains any other character (including whitespace),
    /// when `=` appears anywhere but at the end, or when the unpadded length % 4 == 1.
    /// "" → Data() (empty, not nil).
    public static func decode(_ string: String) -> Data?
}
```

### 3.2 `Encoding/QuotedPrintable.swift`

```swift
/// RFC 2045 §6.7 quoted-printable for text bodies. [mime-rfc §3.3, §8.3]
public enum QuotedPrintable {
    /// Precondition (not checked): `utf8` already uses CRLF line breaks (MIMEBuilder normalises first).
    /// Rules: `=XX` uppercase hex for every octet outside 33…60 / 62…126 and for `=`; SP/TAB literal
    /// except as the LAST octet of a line (→ `=20` / `=09`); CRLF kept; encoded lines ≤ 76 chars
    /// including the soft-break `=`; a token (1 literal or 3-char `=XX`) never straddles a line.
    public static func encode(_ utf8: Data) -> Data

    /// Tolerant decoder: `=XX` with upper- or lowercase hex → octet; `=` + CRLF or `=` + LF → nothing
    /// (soft break); `=` not followed by two hex digits → literal `=`; trailing SP/TAB before a line
    /// break or at end of input dropped; CR/LF bytes passed through unchanged. Never fails.
    public static func decode(_ data: Data) -> Data
}
```

### 3.3 `Encoding/RFC2047.swift`

```swift
/// RFC 2047 encoded-words. [mime-rfc §2.3]
public enum RFC2047 {
    /// Decodes every `=?charset[*lang]?B|Q?text?=` in `headerValue`. LWSP between two ADJACENT encoded-words
    /// is dropped; decoded BYTES of adjacent same-charset words are concatenated before charset decoding
    /// (tolerates UTF-8 sequences split across words); an encoded-word with an unknown charset or
    /// undecodable text is left in the output verbatim. Plain text and the whitespace around it are kept.
    public static func decode(_ headerValue: String) -> String

    /// Returns `text` unchanged when it is "safe ASCII" (every scalar ≤ 0x7F, no control character other
    /// than TAB, no DEL, and `text.count <= 900`). Otherwise returns UTF-8 B encoded-words: the first word
    /// holds at most `max(3, ((76 - firstLineOffset - 12) / 4) * 3)` bytes (and never more than 45), every
    /// later word at most 45 bytes; words never split a unicode scalar; words are joined with CRLF SP.
    /// `firstLineOffset` = number of characters already on the line before the first word ("Subject: " = 9).
    public static func encodeIfNeeded(_ text: String, firstLineOffset: Int) -> String
}
```

### 3.4 `Encoding/RFC2231.swift`

```swift
/// RFC 2231 parameter value continuations and character sets. [mime-rfc §2.4]
public enum RFC2231 {
    /// Looks up `named` (case-insensitive) in `params` as produced by `ContentTypeParams.parse`.
    /// Precedence: `name*=charset'lang'%xx` → continuations `name*0[*]=, name*1[*]=…` → plain `name=`
    /// (an illegal RFC 2047 encoded-word inside a plain value is decoded). nil when absent.
    public static func parameter(named: String, in params: [(String, String)]) -> String?

    /// ASCII filename (no `"`/`\`): `filename="<name>"`. Otherwise:
    /// `filename="<ascii fallback>"; filename*=UTF-8''<percent-encoded UTF-8>` where the fallback replaces every
    /// non-ASCII scalar with `_` and the percent-encoding covers every byte that is not an RFC 2231 attribute-char.
    public static func encodeFilenameParams(_ filename: String) -> String
}
```

### 3.5 `Encoding/Charsets.swift`

```swift
/// Pure IANA charset name table (no CoreFoundation). [mime-rfc §2.3, §5.3]
public enum Charsets {
    /// Trims, strips surrounding quotes, strips a `*lang` suffix (RFC 2231 §5), lowercases, then looks the
    /// name up in the alias table of §5.3. nil for unknown names.
    public static func encoding(forIANA name: String) -> String.Encoding?

    /// Decode chain: `charset` → UTF-8 → ISO-8859-1. Never fails (every byte sequence is valid Latin-1).
    /// A leading UTF-8 BOM (EF BB BF) is removed when the result was decoded as UTF-8.
    public static func decode(_ data: Data, charset: String?) -> String
}
```

### 3.6 `Headers/Mailbox.swift`

```swift
/// One RFC 5322 mailbox. `addr` keeps the original case; comparisons use `key`. [mime-rfc §2.2]
public struct Mailbox: Sendable, Hashable, Codable {
    public var name: String?
    public var addr: String
    public init(name: String?, addr: String)
    public var key: String { addr.lowercased() }
    public var displayName: String { name ?? addr }
    /// `name <addr>`: name unquoted when every character is atext or SP; RFC 5322 quoted-string
    /// (`"` and `\` escaped) when ASCII with specials; RFC 2047 B encoded-word(s) when non-ASCII
    /// (`RFC2047.encodeIfNeeded(name, firstLineOffset: 0)`). `name == nil` or empty/blank → bare `addr`.
    public func serialized() -> String
}
```

### 3.7 `Headers/AddressParser.swift`

```swift
/// RFC 5322 §3.4 address-list tokenizer (not a regex). [mime-rfc §2.2, §8.4]
public enum AddressParser {
    /// Unfolds, splits on top-level commas (outside quotes, comments, `<…>`), flattens groups (name dropped),
    /// drops obs-route (`<@a,@b:user@dom>` → `user@dom`), uses a trailing comment as display name for the
    /// legacy `addr (Name)` form, decodes RFC 2047 words in display names, drops null members (`a,, ,b`).
    /// Never throws; garbage yields [] or a best-effort mailbox with the raw text as `addr`.
    public static func parseList(_ headerValue: String) -> [Mailbox]
    /// `parseList(headerValue).first`
    public static func parseFirst(_ headerValue: String) -> Mailbox?
}
```

### 3.8 `Headers/HeaderDate.swift`

```swift
/// RFC 5322 §3.3 dates and the Gmail attribution date. [mime-rfc §1.3, §4.1, §5.5]
public enum HeaderDate {
    /// "Fri, 11 Sep 2026 10:00:00 +0200" — DateFormatter, locale en_US_POSIX, format "EEE, d MMM yyyy HH:mm:ss Z".
    public static func rfc5322(_ date: Date, timeZone: TimeZone) -> String
    /// Tolerant parse: optional day-of-week, comments in parentheses, 2-digit years (00–49 → 20xx, 50–99 → 19xx),
    /// 3-digit years (+1900), missing seconds, numeric `±HHMM` zones, named zones UT/GMT/Z/EST/EDT/CST/CDT/
    /// MST/MDT/PST/PDT, any other alphabetic zone = +0000. nil when day/month/year/time cannot be read.
    public static func parse(_ value: String) -> Date?
    /// "Thu, Sep 10, 2026 at 9:12\u{202F}AM" — locale en_US_POSIX, format "EEE, MMM d, yyyy 'at' h:mm\u{202F}a". [mime-rfc §4.1]
    public static func attribution(_ date: Date, timeZone: TimeZone) -> String
}
```

### 3.9 `Headers/HeaderFolding.swift`

```swift
public enum HeaderFolding {
    /// Removes every CRLF, lone LF or lone CR that is immediately followed by SP or TAB (the WSP is kept);
    /// then strips trailing CR/LF. RFC 5322 §2.2.3.
    public static func unfold(_ raw: String) -> String
    /// "<fieldName>: m1, m2, …" using `Mailbox.serialized()`; when appending ", mN" would push the current
    /// line past 78 characters the separator becomes "," CRLF SP. No trailing CRLF. Empty list → "<fieldName>:".
    public static func foldAddressList(_ list: [Mailbox], fieldName: String) -> String
    /// "<fieldName>: <a> <b>"; when appending " <id>" would exceed 78 the separator becomes CRLF SP
    /// (one id per continuation line). No trailing CRLF. Empty list → "<fieldName>:".
    public static func foldMessageIDs(_ ids: [String], fieldName: String) -> String
}
```

### 3.10 `Headers/ContentTypeParams.swift`

```swift
/// Parsed `type/subtype; name=value; …`. [mime-rfc §2.4, §5.3]
public struct ContentTypeValue: Sendable, Equatable {
    public var type: String                     // lowercased, trimmed, e.g. "text/html"; "" when absent
    public var params: [(String, String)]       // (name as written, value with quotes removed and quoted-pairs unescaped), in order
    public init(type: String, params: [(String, String)])                       // ADDITION
    /// First parameter whose name matches case-insensitively; nil when absent.
    public func param(_ name: String) -> String?
    // DEVIATION: `[(String, String)]` cannot synthesise Equatable; `==` is implemented by hand
    // (same `type`, same count, pairwise equal names and values). Call sites are unchanged.
    public static func == (lhs: ContentTypeValue, rhs: ContentTypeValue) -> Bool
}
public enum ContentTypeParams {
    /// Tokenizer: value before the first top-level `;` is the type; each following `name=value` (value
    /// quoted-string or token) is a parameter; parameters without `=` are ignored; whitespace and RFC 5322
    /// comments outside quotes are ignored. Never throws.
    public static func parse(_ headerValue: String) -> ContentTypeValue
}
```

### 3.11 `Headers/MessageIDs.swift`

```swift
public enum MessageIDs {
    /// "<a> <b>" → ["<a>", "<b>"]: every `<…>` token in reading order; text outside angle brackets and empty
    /// `<>` dropped; works without whitespace between tokens (`<a><b>`) and across folded lines.
    public static func split(_ referencesValue: String) -> [String]
    /// Trims whitespace; adds missing `<` / `>`; nil when the inside is empty or contains whitespace (an `@` is NOT required — Gmail-synthesised ids are kept as-is).
    public static func normalize(_ id: String) -> String?
    /// "<UUID@domain>" (uppercase UUID string). Empty `domain` → "localhost".
    public static func generate(domain: String, uuid: UUID = UUID()) -> String
    /// RFC 5322 §3.6.4: base = parent References if non-empty, else parent In-Reply-To if it holds exactly one id,
    /// else []; then + parent Message-ID; every id normalised; duplicates removed keeping the first occurrence.
    public static func referencesChain(parentReferences: [String], parentInReplyTo: String?, parentMessageID: String?) -> [String]
}
```

### 3.12 `MIME/OutgoingMessage.swift`

```swift
/// [mime-rfc §1.3, §3, §7]
public struct OutgoingAttachment: Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    public init(filename: String, mimeType: String, data: Data)                 // ADDITION
}
public struct OutgoingMessage: Sendable, Equatable {
    public var from: Mailbox
    public var to: [Mailbox]
    public var cc: [Mailbox]
    public var subject: String
    public var date: Date
    public var timeZone: TimeZone
    public var messageID: String
    public var inReplyTo: String?
    public var references: [String]
    public var textBody: String                 // "\n", "\r\n" or "\r" line breaks — normalised by the builder
    public var htmlBody: String                 // full <html> document in production (OutgoingBodies.document); any fragment accepted
    public var attachments: [OutgoingAttachment]
    public init(from: Mailbox, to: [Mailbox], cc: [Mailbox], subject: String, date: Date, timeZone: TimeZone,
                messageID: String, inReplyTo: String?, references: [String], textBody: String, htmlBody: String,
                attachments: [OutgoingAttachment])                                                     // ADDITION
}
public struct BoundaryGenerator: Sendable {
    /// "=_minimail_<kind>_<16 lowercase hex from SystemRandomNumberGenerator>" — a fresh value per call.
    public static let random: BoundaryGenerator
    /// kind "alt" → `alt`, kind "mixed" → `mixed`, any other kind → "=_minimail_<kind>_0000000000000000".
    public static func fixed(alt: String, mixed: String) -> BoundaryGenerator
    public func boundary(kind: String) -> String
    // internal: private let make: @Sendable (String) -> String
}
```

### 3.13 `MIME/MIMEBuilder.swift`

```swift
public enum MIMEBuilder {
    /// CRLF; header order From, To, Cc?, Subject, Date, Message-ID, In-Reply-To?, References?, MIME-Version, Content-Type;
    /// structure A (alternative: plain then html, QP) or B (mixed ⊃ A + base64 76-col attachments, RFC 2231 names).
    /// Output ends with CRLF. Never throws. Deterministic for a fixed `boundaries`. See §4.13.
    public static func build(_ m: OutgoingMessage, boundaries: BoundaryGenerator = .random) -> Data
}
```

### 3.14 `Compose/ComposeStyle.swift`

```swift
/// Default font / size / colour for the typed part of outgoing mail. [html-rendering §5.3, §5.4]
public struct ComposeStyle: Codable, Equatable, Sendable {
    public enum Family: String, Codable, CaseIterable, Sendable {
        case helvetica, arial, verdana, tahoma, trebuchet, georgia, times, courier
        public var css: String            // exact stacks of §5.3 below (with the spaces after commas)
        public var displayName: String    // "Helvetica", "Arial", "Verdana", "Tahoma", "Trebuchet MS", "Georgia", "Times New Roman", "Courier New"
    }
    public static let minSizePx = 12                                          // ADDITION
    public static let maxSizePx = 18                                          // ADDITION
    public static let defaultColorHex = "#000000"                             // ADDITION
    public var family: Family = .helvetica
    public var sizePx: Int = 14                                               // clamped 12…18 (on decode and in inlineCSS)
    public var colorHex: String = "#000000"                                   // ^#[0-9a-f]{6}$ (validated on decode and in inlineCSS)
    public var inlineCSS: String { "font-family:\(family.css);font-size:\(sizePx)px;color:\(colorHex)" }   // uses the clamped/validated values, see §4.14
    public init()
    public init(family: Family, sizePx: Int, colorHex: String)                // ADDITION — clamps and validates
    /// true iff `hex` matches ^#[0-9a-f]{6}$ exactly (lowercase only).
    public static func isValidColorHex(_ hex: String) -> Bool                 // ADDITION
    /// Lowercases; returns the input when valid, else nil.
    public static func normalizedColorHex(_ hex: String) -> String?           // ADDITION
    // Codable: custom init(from:) — every field decodeIfPresent with the default as fallback; unknown Family
    // raw value → .helvetica; sizePx clamped; colorHex normalised or "#000000". encode(to:) is synthesised.
}
```

### 3.15 `Compose/ReplyAll.swift`

```swift
public struct SelfIdentity: Sendable, Equatable {
    public var primary: Mailbox
    public var allAddresses: Set<String>        // lowercased addr-specs; always contains primary.key
    /// Inserts `primary.key` and lowercases every element of `allAddresses`.
    public init(primary: Mailbox, allAddresses: Set<String>)                  // ADDITION
}
public struct Recipients: Sendable, Equatable {
    public var to: [Mailbox]
    public var cc: [Mailbox]
    public init(to: [Mailbox], cc: [Mailbox])                                 // ADDITION
}
public enum ReplyAll {
    /// Architecture §7.1 / [mime-rfc §2.1]; see §4.15.
    public static func recipients(from: Mailbox?, replyTo: [Mailbox], to: [Mailbox], cc: [Mailbox], me: SelfIdentity) -> Recipients
}
```

### 3.16 `Compose/SubjectPrefix.swift`

```swift
public enum SubjectPrefix {
    /// Trims whitespace; "Re: " + s unless s.lowercased().hasPrefix("re:").
    public static func reply(_ s: String) -> String
    /// Trims whitespace; "Fwd: " + s unless s.lowercased().hasPrefix("fwd:").
    public static func forward(_ s: String) -> String
    /// Repeatedly strips a leading prefix from {re:, fwd:, fw:, aw:, wg:} (case-insensitive, optional
    /// whitespace before and after, optional "[n]" counter as in "Re[2]:"); returns the trimmed remainder ("" possible).
    public static func stripForDisplay(_ s: String) -> String
}
```

### 3.17 `Compose/Quoting.swift`

```swift
public enum ComposeMode: String, Codable, Sendable { case replyAll, forward }

/// Snapshot of the original taken at compose time (stored in SendJob JSON by module 11, consumed by module 07).
public struct QuoteSource: Codable, Sendable, Equatable {
    public var author: Mailbox?
    public var date: Date
    public var subject: String
    public var to: [Mailbox]
    public var cc: [Mailbox]
    public var html: String?     // quotable HTML (QuoteExtractor output) — data-src restored, cid <img> removed, mm-* classes removed
    public var text: String?     // plain text alternative
    public init(author: Mailbox?, date: Date, subject: String, to: [Mailbox], cc: [Mailbox], html: String?, text: String?)   // ADDITION
}

public enum Quoting {
    /// "On {HeaderDate.attribution(date, tz)} {author.displayName} <{author.addr}> wrote:"; author nil → "On {attribution} wrote:".
    public static func attributionLine(author: Mailbox?, date: Date, timeZone: TimeZone) -> String
    /// gmail_quote_container + gmail_attr + blockquote [mime-rfc §4.1]; exact string in §4.17.
    public static func replyHTML(_ q: QuoteSource, timeZone: TimeZone) -> String
    /// attribution + "\n" + "> "-prefixed lines (">" for empty lines); no trailing "\n".
    public static func replyText(_ q: QuoteSource, timeZone: TimeZone) -> String
    /// "---------- Forwarded message ---------" banner block, body NOT blockquoted [mime-rfc §4.2]; exact string in §4.17.
    public static func forwardHTML(_ q: QuoteSource, timeZone: TimeZone) -> String
    /// banner + From/Date/Subject/To[/Cc] + two blank lines + text; no trailing "\n".
    public static func forwardText(_ q: QuoteSource, timeZone: TimeZone) -> String
    /// Crude tag strip + entity decode (§4.17.6). Never throws.
    public static func textFromHTML(_ html: String) -> String
}
```

### 3.18 `Compose/OutgoingBodies.swift`

```swift
public enum OutgoingBodies {
    /// & → &amp;  < → &lt;  > → &gt;  " → &quot;  (nothing else)
    public static func escape(_ s: String) -> String
    /// <div dir="ltr" class="minimail_default" style="{inlineCSS}"> one <div> per line </div> [+ signature block] + quote OUTSIDE the wrapper [html-rendering §5.5]
    public static func html(typed: String, style: ComposeStyle, signatureHTML: String?, quoteHTML: String?) -> String
    /// <html><head><meta charset="utf-8"></head><body>…</body></html>, no color-scheme meta
    public static func document(bodyFragment: String) -> String
    /// typed, blank, "-- " + sig, blank, quote  ("\n" line breaks, no trailing "\n")
    public static func text(typed: String, signatureText: String?, quoteText: String?) -> String
}
```

### 3.19 `Compose/PlainTextHTML.swift`

```swift
public enum PlainTextHTML {
    /// escape, linkify https?:// and www., <div> per line, wrapped in <div class="mm-plaintext">  (§4.19)
    public static func convert(_ text: String) -> String
}
```

### 3.20 Test support (internal to `MailCoreTests`)

```swift
// Tests/MailCoreTests/Support/Fixtures.swift
import Foundation
import XCTest

enum Fixture {
    /// Reads `Fixtures/<relativePath>` from `Bundle.module`; throws `FixtureError.missing(path)` when absent.
    static func data(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data
    static func string(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String   // UTF-8
    static func json<T: Decodable>(_ relativePath: String, as: T.Type, file: StaticString = #filePath, line: UInt = #line) throws -> T
    /// Reads `<relativePath>` (a `.sha256` file) and returns the first 64 hex characters.
    static func sha256Hex(_ relativePath: String) throws -> String
}
```

---

## 4. Behaviour

Numbering follows §3. Every algorithm operates on `Array(string.utf8)` or `string.unicodeScalars`; never on `Character` views for byte-exact output (Swift treats CRLF as one `Character`, `[mime-rfc §9]`).

### 4.1 `Base64URL`

**encode(data):**
1. `let s = data.base64EncodedString()` (no options → single line, padded).
2. Replace every `+` with `-` and every `/` with `_` (byte-wise over `Array(s.utf8)`), return the result.

**decode(string):**
1. `var bytes = Array(string.utf8)`. If empty → return `Data()`.
2. For each byte: `-` → `+`, `_` → `/`; allowed set = `A–Z a–z 0–9 + / =`; any other byte → return nil.
3. Strip trailing `=` bytes (at most 2; a third `=` or an `=` before the end → nil).
4. `rem = bytes.count % 4`; `rem == 1` → nil; `rem == 2` → append `==`; `rem == 3` → append `=`.
5. Return `Data(base64Encoded: Data(bytes))` (nil if Foundation rejects it — UNVERIFIED strictness, covered by tests).

Edge cases: `"Zg"` → `0x66`; `"Zg=="` → `0x66`; `"-_-_"` → `FB FF BF`; `"+/+/"` → same; `"Zg=x"` → nil; `"Z g"` → nil.

### 4.2 `QuotedPrintable`

**encode(utf8):** (verified byte-exact against `[mime-rfc §7.1, §7.2]`)
```
out = []; lines = split(utf8, on: CRLF)               // keep an empty final element when input ends with CRLF
for (i, line) in lines.enumerated():
    if i == lines.count - 1 && line.isEmpty: break      // input ended with CRLF: nothing after the last CRLF
    cur = []
    for (j, b) in line.enumerated():
        isLast = (j == line.count - 1)
        literal = (33...60).contains(b) || (62...126).contains(b) || ((b == 0x20 || b == 0x09) && !isLast)
        tok = literal ? [b] : [0x3D, HEX[b >> 4], HEX[b & 0x0F]]     // HEX = "0123456789ABCDEF"
        if cur.count + tok.count > 75: out += cur + [0x3D] + CRLF; cur = []
        cur += tok
    out += cur
    if i < lines.count - 1: out += CRLF
return Data(out)
```
Properties: every encoded line ≤ 76 chars (75 + `=`); `=XX` never split; a lone CR or LF inside a line (not part of CRLF) is encoded as `=0D` / `=0A` (precondition says there are none). Vectors: `Grüße` → `Gr=C3=BC=C3=9Fe`; `a=b` → `a=3Db`; `trailing space ` → `trailing space=20`; `tab\tend\t` → `tab\tend=09`; 80 × `x` → 75 × `x` + `=` CRLF + 5 × `x`; `Viele Grüße\r\nMax` → `Viele Gr=C3=BC=C3=9Fe\r\nMax`; `-- ` → `--=20`.

**decode(data):** single pass over bytes with a pending-whitespace buffer:
```
i = 0; out = []; ws = []
while i < n:
    b = data[i]
    if b == 0x20 || b == 0x09: ws.append(b); i += 1; continue
    if b == 0x0D || b == 0x0A: ws = []; out.append(b); i += 1; continue          // trailing WSP dropped
    out += ws; ws = []
    if b == 0x3D:
        if i + 2 <= n - 1 && isHex(data[i+1]) && isHex(data[i+2]): out.append(hexValue); i += 3; continue
        if i+2 < n && data[i+1] == 0x0D && data[i+2] == 0x0A: i += 3; continue      // soft break CRLF
        if i+1 < n && data[i+1] == 0x0A: i += 2; continue                          // soft break LF
        out.append(0x3D); i += 1; continue                                          // lone "="
    out.append(b); i += 1
return Data(out)            // pending ws at end of input is dropped
```
(`isHex` accepts `0-9 A-F a-f`.)

### 4.3 `RFC2047`

**decode(headerValue):** scanner over `Array(headerValue.utf8)`:
```
result = []           // bytes appended as UTF-8
pendingBytes = []; pendingCharset: String? = nil     // decoded bytes of consecutive same-charset words
wsBuffer = []         // SP/TAB/CR/LF seen since the last non-space token
lastWasWord = false
i = 0
while i < n:
    if bytes[i] == '=' && i+1 < n && bytes[i+1] == '?', let w = parseEncodedWord(at: i):   // w = (charset, encoding, text, endIndex)
        // parseEncodedWord: "=?" charset "?" ("B"|"b"|"Q"|"q") "?" text "?="; charset and text may not contain "?" or SP;
        // charset = part before the first "*" (RFC 2231 lang suffix stripped); fails when any piece is empty or no closing "?=" exists
        enc = Charsets.encoding(forIANA: w.charset)
        decodedBytes = (w.encoding is B) ? Base64URL.decode(w.text) : decodeQ(w.text)
        if enc == nil || decodedBytes == nil:                       // unknown charset / undecodable → verbatim
            flushPending(); result += wsBuffer; wsBuffer = []; result += bytes[i..<w.endIndex]; lastWasWord = false; i = w.endIndex; continue
        if lastWasWord: wsBuffer = []                               // LWSP between adjacent encoded-words ignored (§6.2)
        else: flushPending(); result += wsBuffer; wsBuffer = []
        if pendingCharset != w.charsetLowercased: flushPending(); pendingCharset = w.charsetLowercased
        pendingBytes += decodedBytes; lastWasWord = true; i = w.endIndex; continue
    if bytes[i] in {SP, TAB, CR, LF}: wsBuffer.append(bytes[i]); i += 1; continue
    flushPending(); result += wsBuffer; wsBuffer = []; result.append(bytes[i]); lastWasWord = false; i += 1
flushPending(); result += wsBuffer
return String(decoding: result, as: UTF8.self)
flushPending(): if !pendingBytes.isEmpty: result += Array(Charsets.decode(Data(pendingBytes), charset: pendingCharset).utf8); pendingBytes = []
decodeQ(text): "_" → 0x20; "=" + 2 hex (either case) → byte; "=" otherwise → literal "="; every other byte literal
```
`Base64URL.decode` is used for B because it accepts the standard alphabet and missing padding (`=?UTF-8?B?w6Q?=` → `ä`). Vectors: the 9 rows of `[mime-rfc §8.3]` (§5.4 `rfc2047.json`).

**encodeIfNeeded(text, firstLineOffset):**
1. `safe = text.unicodeScalars.allSatisfy { $0.value <= 0x7E && ($0.value >= 0x20 || $0.value == 0x09) } && text.count <= 900` → return `text`.
2. `firstLimit = min(45, max(3, ((76 - firstLineOffset - 12) / 4) * 3))`; `laterLimit = 45`.
3. Chunk `text.unicodeScalars` greedily: start a new chunk when adding the next scalar's UTF-8 length would exceed the current limit (first chunk `firstLimit`, later chunks `laterLimit`). A single scalar always fits (limit ≥ 3 ≥ 4 bytes is not guaranteed for `firstLimit = 3`; a 4-byte scalar in a chunk of its own is accepted — the word is then 20 characters long, still ≤ 75).
4. Each chunk → `"=?UTF-8?B?" + Data(chunk.utf8).base64EncodedString() + "?="`.
5. Join with `"\r\n "` (CRLF SP). Return.

Examples: `"Re: Angebot für die Erweiterung"` (34 bytes, offset 9, limit 39) → `=?UTF-8?B?UmU6IEFuZ2Vib3QgZsO8ciBkaWUgRXJ3ZWl0ZXJ1bmc=?=`; `"Alice Müller"` (offset 0) → `=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?=`; 56-byte `"ÄÖÜäöüß" × 4` with offset 9 → two words (39 bytes = 19 scalars + 1 byte... the greedy scalar rule gives chunk 1 = 19 scalars = 38 bytes, chunk 2 = 9 scalars = 18 bytes) joined by CRLF SP; `RFC2047.decode` of the result equals the input.

### 4.4 `RFC2231`

**parameter(named:in:)** — `target = named.lowercased()`:
1. If a pair exists with `name.lowercased() == target + "*"` → return `decodeExtended(value)` where `decodeExtended` splits on the first two `'`: `charset`, `lang` (ignored), `payload`; percent-decodes `payload` (`%XX`, either case; a malformed `%` kept literally) into bytes; returns `Charsets.decode(bytes, charset: charset.isEmpty ? "utf-8" : charset)`.
2. Collect pairs whose lowercased name is `target + "*" + digits` or `target + "*" + digits + "*"`; parse the digits; sort ascending by number. If non-empty: `bytes = []`, `charset = "utf-8"`; for the segment with number 0 and a trailing `*`, split off `charset'lang'` (first two `'`) and remember the charset; for every starred segment append the percent-decoded bytes; for every unstarred segment append its UTF-8 bytes; return `Charsets.decode(bytes, charset)`.
3. If a pair exists with `name.lowercased() == target` → `v = value`; return `v.contains("=?") ? RFC2047.decode(v) : v`.
4. Return nil.

Rows (`[mime-rfc §8.3]` RFC 2231 table, §5.4 `rfc2231.json`): all 6 rows produce the listed filename when the input string is first run through `ContentTypeParams.parse` and then `RFC2231.parameter(named: "filename", in: ct.params)`.

**encodeFilenameParams(filename):**
1. `isASCII = filename.unicodeScalars.allSatisfy { $0.value < 0x80 }`. If `isASCII` and the name contains neither `"` nor `\`: return `filename="\(filename)"`.
2. `fallback` = filename with every scalar ≥ 0x80 replaced by `_`, then `"` → `\"` and `\` → `\\`.
3. `pct` = for every byte of `filename.utf8`: keep when it is an attribute-char (ASCII 0x21…0x7E excluding `*'%()<>@,;:\"/[]?=`), else `%` + two uppercase hex digits.
4. Return `filename="\(fallback)"; filename*=UTF-8''\(pct)`.

Example: `Ängebot.pdf` → `filename="_ngebot.pdf"; filename*=UTF-8''%C3%84ngebot.pdf`; `Angebot 2026.pdf` (ASCII with space) → `filename="Angebot 2026.pdf"`.

### 4.5 `Charsets`

**encoding(forIANA:)**: `n = name.trimmingCharacters(in: .whitespacesAndNewlines)`; strip one leading and one trailing `"`; cut at the first `*`; lowercase; look up in the table of §5.3; nil if absent.

**decode(data, charset:)**:
```
if let cs = charset, let enc = encoding(forIANA: cs), let s = String(data: data, encoding: enc) { return strippingBOM(s, ifUTF8: enc == .utf8) }
if let s = String(data: data, encoding: .utf8) { return strippingBOM(s) }
return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
```
`strippingBOM` removes a leading U+FEFF. Whether `String(data:encoding:)` supports every table entry on Linux is UNVERIFIED (§10); the chain guarantees a non-empty result for non-empty input regardless.

### 4.6 `Mailbox`

**serialized():**
1. `let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)`; if `n.isEmpty` → return `addr`.
2. If `n` has a non-ASCII scalar → return `RFC2047.encodeIfNeeded(n, firstLineOffset: 0) + " <" + addr + ">"`.
3. `atextOrSpace` = ASCII letters, digits, SP and the characters ! # $ % & ' * + - / = ? ^ _ { | } ~ and the backtick (RFC 5322 §3.2.3 atext). If every scalar of `n` is in that set → `n + " <" + addr + ">"`.
4. Else → `"\"" + n.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" <" + addr + ">"`.

Examples: `("Max Mustermann", "max.mustermann@newtelco.de")` → `Max Mustermann <max.mustermann@newtelco.de>`; `("Müller, Alice", …)` → `=?UTF-8?B?TcO8bGxlciwgQWxpY2U=?= <alice@example.com>`; `("J. Doe", …)` → `"J. Doe" <…>` (`.` is not atext); `("Bob \"The Builder\"", …)` → `"Bob \"The Builder\"" <…>`; `(nil, "bob@example.com")` → `bob@example.com`.

### 4.7 `AddressParser`

**parseList(headerValue):**

Phase 1 — split into items (scalar scanner with state `inQuote`, `commentDepth`, `inAngle`, `inGroup`):
```
s = HeaderFolding.unfold(headerValue); items = []; cur = ""
for each scalar c (with index):
    if inQuote:            if c == "\\" and a next scalar exists: cur += c + next; skip next
                           elif c == "\"": inQuote = false; cur += c
                           else: cur += c
    elif commentDepth > 0: if c == "\\" and next exists: cur += c + next; skip next
                           elif c == "(": commentDepth += 1; cur += c
                           elif c == ")": commentDepth -= 1; cur += c
                           else: cur += c
    else: switch c:
        "\"": inQuote = true; cur += c
        "(":  commentDepth = 1; cur += c
        "<":  inAngle = true; cur += c
        ">":  inAngle = false; cur += c
        ",":  if inAngle: cur += c  else: items.append(cur); cur = ""
        ":":  if inAngle || inGroup: cur += c  else: inGroup = true; cur = ""          // group display-name dropped
        ";":  if inAngle: cur += c  elif inGroup: items.append(cur); cur = ""; inGroup = false  else: cur += c
        default: cur += c
items.append(cur)
```
Phase 2 — `parseMailbox(item) -> Mailbox?` for each item, dropping nils:
```
t = item.trimmingCharacters(in: .whitespacesAndNewlines); if t.isEmpty → nil
find lt = index of the LAST "<" that is outside quotes and comments; gt = the first ">" after lt outside quotes/comments
if both exist:
    addrRaw = t[lt+1 ..< gt]; namePart = t[..<lt]
    if addrRaw.hasPrefix("@"), let colon = addrRaw.lastIndex(of: ":"): addrRaw = addrRaw[after colon]     // obs-route
    addr = addrRaw with comments removed (depth-aware, outside quotes) and every SP/TAB outside quotes removed
    name = decodePhrase(namePart)
else:
    comments = every top-level "(…)" of t (depth-aware, outside quotes), in order, inner text with quoted-pairs unescaped
    addr = t with those comments removed, then trimmed; SP/TAB outside quotes removed
    name = comments.last.map(RFC2047.decode)?.trimmed; empty → nil
if addr.isEmpty → nil
return Mailbox(name: name, addr: addr)

decodePhrase(p):
    remove top-level comments; walk scalars: a quoted-string contributes its unescaped content, other runs are kept verbatim
    joined = collapse runs of SP/TAB to one SP, trimmed
    result = RFC2047.decode(joined).trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
```
Guaranteed rows: the 10 rows of `[mime-rfc §8.4]` (§5.4 `addresses.json`) plus: `Team: max.mustermann@newtelco.de, bob@example.com;` → 2 mailboxes; `undisclosed-recipients:;` → `[]`; `bob@example.com,, ,carol@partner.example` → 2; `Bob <@relay.example:bob@example.com>` → `("Bob", "bob@example.com")`; `"Alice (Sales)" <a@b>` → name `Alice (Sales)` (parentheses inside quotes are not a comment).

**parseFirst** = `parseList(headerValue).first`.

### 4.8 `HeaderDate`

**rfc5322 / attribution:** create `DateFormatter()`, set `locale = Locale(identifier: "en_US_POSIX")`, `timeZone`, `calendar = Calendar(identifier: .gregorian)`, `dateFormat` = `"EEE, d MMM yyyy HH:mm:ss Z"` or `"EEE, MMM d, yyyy 'at' h:mm\u{202F}a"`; return `string(from:)`. Examples for `Date(timeIntervalSince1970: 1789113600)`: Europe/Berlin → `Fri, 11 Sep 2026 10:00:00 +0200`; UTC → `Fri, 11 Sep 2026 08:00:00 +0000`. Attribution of `Date(timeIntervalSince1970: 1789024353)` in Europe/Berlin → `Thu, Sep 10, 2026 at 9:12\u{202F}AM` (UTF-8 bytes `... 39 3A 31 32 E2 80 AF 41 4D`); `1789113600` UTC → `Fri, Sep 11, 2026 at 8:00\u{202F}AM`; 12:00 local → `12:00\u{202F}PM`; 00:05 local → `12:05\u{202F}AM`.

**parse(value):**
1. Remove every parenthesised comment (depth-aware); replace `,` with SP; collapse whitespace; split on SP → `tok`.
2. If `tok[0]` is alphabetic and `tok.count >= 5` and `tok[1]` is numeric → drop `tok[0]` (day-of-week). If `tok[0]` is alphabetic and `tok[1]` is alphabetic → nil.
3. Need `tok.count >= 4`: `day = Int(tok[0])`, `month = ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"].firstIndex(of: tok[1].prefix(3).lowercased()) + 1`, `year = Int(tok[2])`; any nil → nil. `year < 50` → `+2000`; `50 ≤ year < 100` → `+1900`; `100 ≤ year < 1000` → `+1900`.
4. `time = tok[3].split(":")`: 2 or 3 numeric parts → `h, m, s (default 0)`; else nil. Ranges: day 1…31, h 0…23, m 0…59, s 0…60; else nil.
5. Zone `z = tok.count >= 5 ? tok[4] : "+0000"`: `[+-]` + 4 digits → `sign * (HH*3600 + MM*60)`; uppercase name table `UT, UTC, GMT, Z → 0`, `EST → -5h, EDT → -4h, CST → -6h, CDT → -5h, MST → -7h, MDT → -6h, PST → -8h, PDT → -7h`; any other token → 0.
6. `Calendar(identifier: .gregorian)` with `timeZone = TimeZone(secondsFromGMT: offset)`, `DateComponents(year:month:day:hour:minute:second:)` → `calendar.date(from:)`; nil when the calendar rejects it.

Rows: `Thu, 10 Sep 2026 09:12:33 +0200` → 1789024353; `10 Sep 2026 09:12:33 +0200` → same; `Thu, 10 Sep 26 09:12 +0200` → 1789024320; `Thu, 10 Sep 2026 07:12:33 GMT` → 1789024353; `Thu, 10 Sep 2026 03:12:33 EDT` → 1789024353; `Thu, 10 Sep 2026 09:12:33 +0200 (CEST)` → 1789024353; `Thu,10 Sep 2026 09:12:33 +0200` → 1789024353; `garbage` → nil; `"" ` → nil; `32 Sep 2026 00:00:00 +0000` → nil.

### 4.9 `HeaderFolding`

**unfold(raw):** scan scalars; when the current scalar is CR and the next is LF and the one after is SP/TAB → skip CR+LF; when the current scalar is LF or CR and the next is SP/TAB → skip it; otherwise copy. Finally drop trailing CR/LF scalars. `"Alice\r\n <alice@example.com>"` → `"Alice <alice@example.com>"`; `"a\r\nb"` (no WSP) → unchanged.

**foldAddressList(list, fieldName):**
```
line = fieldName + ":"; out = ""; first = true
for m in list:
    piece = m.serialized()                              // may itself contain CRLF SP from RFC2047 folding — its length is measured up to its first CRLF
    if first: line += " " + piece; first = false
    elif (lengthOfLastLine(line) + 2 + lengthOfFirstLine(piece)) > 78: out += line + "," + CRLF; line = " " + piece
    else: line += ", " + piece
return out + line
```
Empty list → `fieldName + ":"`. `lengthOfLastLine` counts characters after the last CRLF in `line`. Example: 5 mailboxes of 25 characters under `To` → lines `To: a, b` / ` c, d` / ` e` (each ≤ 78).

**foldMessageIDs(ids, fieldName):** same loop with separator `" "` and continuation `CRLF + " "` (no comma); an id longer than 77 characters stays on its own line untouched. `References: <older-id@example.com> <CAF=abc123@mail.example.com>` (65 chars) stays on one line.

### 4.10 `ContentTypeParams`

**parse(headerValue):**
1. `s = HeaderFolding.unfold(headerValue)`; remove top-level comments (depth-aware, outside quotes).
2. Split `s` on `;` outside quotes → `segments`. `type = segments[0].trimmed.lowercased()` (`""` when missing).
3. For each later segment: find the first `=`; none → skip. `name = before.trimmed` (kept as written), `rawValue = after.trimmed`. If `rawValue` starts with `"`: take up to the matching unescaped closing `"` (missing → to end), unescape `\x` → `x`. Else `value = rawValue` up to the first SP/TAB. Empty names are skipped.
4. Return `ContentTypeValue(type:, params:)`.

Rows: `text/html; charset="UTF-8"` → type `text/html`, `param("charset") == "UTF-8"`, `param("CHARSET") == "UTF-8"`; `multipart/alternative; boundary="=_minimail_alt_7c1e3f2a9b4d4e6f"` → `param("boundary") == "=_minimail_alt_7c1e3f2a9b4d4e6f"`; `Text/Plain;charset=iso-8859-1` → type `text/plain`, charset `iso-8859-1`; `multipart/mixed; boundary=abc (comment); x` → boundary `abc`, no `x` param; `""` → type `""`, no params; `attachment; filename*0*=utf-8''%C3%84nge; filename*1*=bot; filename*2=".pdf"` → 3 params named `filename*0*`, `filename*1*`, `filename*2`.

### 4.11 `MessageIDs`

**split:** scan for `<`; take the substring up to the next `>`; drop if the inner text is empty; continue after `>`; anything outside angle brackets is ignored. `"<a@x> junk <b@y>"` → `["<a@x>", "<b@y>"]`; `"<a@x><b@y>"` → both; `"<a@x>\r\n <b@y>"` → both; `"no ids"` → `[]`; `"<>"` → `[]`.

**normalize:** trim whitespace; prepend `<` if missing; append `>` if missing; nil when the inside contains SP/TAB/CR/LF or is empty. `" CAF=abc@mail.example.com "` → `<CAF=abc@mail.example.com>`; `"<x>"` → `"<x>"`; `"<a b@c>"` → nil; `""` → nil.

**generate:** `"<\(uuid.uuidString)@\(domain.isEmpty ? "localhost" : domain)>"`. Fixed UUID `7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70` with `newtelco.de` → `<7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70@newtelco.de>`.

**referencesChain:**
```
base = parentReferences.compactMap(normalize)
if base.isEmpty, let irt = parentInReplyTo { let ids = split(irt).compactMap(normalize); if ids.count == 1 { base = ids } }
if let mid = parentMessageID.flatMap(normalize) { base.append(mid) }
return dedupe preserving first occurrence
```
Cases: (refs `[<older>]`, irt nil, mid `<CAF>`) → `[<older>, <CAF>]`; (refs `[]`, irt `<p>`, mid `<CAF>`) → `[<p>, <CAF>]`; (refs `[]`, irt `<p> <q>`, mid `<CAF>`) → `[<CAF>]`; (all nil/empty) → `[]`; (refs `[<a>, <CAF>]`, irt nil, mid `<CAF>`) → `[<a>, <CAF>]`; (refs `[]`, irt nil, mid `"CAF@x"`) → `[<CAF@x>]`.

### 4.12 `OutgoingMessage`, `BoundaryGenerator`

`BoundaryGenerator.random.boundary(kind:)` → `"=_minimail_\(kind)_" + 16 lowercase hex digits` from `UInt64.random(in: 0...UInt64.max, using: &SystemRandomNumberGenerator())` formatted with `String(format:)`-free code (`String(value, radix: 16)` left-padded with `0` to 16). Two consecutive calls differ (test asserts inequality). `.fixed(alt:mixed:)` returns exactly the given strings for kinds `"alt"` / `"mixed"`.

### 4.13 `MIMEBuilder.build(m, boundaries:)` — verified byte-exact against `[mime-rfc §7.1, §7.2]`

Helpers (internal, byte-level):
- `normalizeCRLF(_ s: String) -> [UInt8]`: bytes with `CRLF` → `LF`, lone `CR` → `LF`, then every `LF` → `CRLF`.
- `ensureTrailingCRLF(_ b: [UInt8]) -> [UInt8]`: append `CRLF` unless `b` already ends with `CRLF` (empty → `CRLF`).
- `base64Lines(_ d: Data) -> [UInt8]`: `Array(d.base64EncodedData())` (standard alphabet, padded) chunked into 76-byte slices joined by `CRLF`, **no** trailing `CRLF`; empty data → `[]`.
- `part(headers: [String], body: [UInt8]) -> [UInt8]`: each header + `CRLF`, then `CRLF`, then `body`.
- `multipart(boundary: String, parts: [[UInt8]]) -> [UInt8]`: for each part `"--" + boundary + CRLF + part + CRLF`; then `"--" + boundary + "--"` (no trailing CRLF — the enclosing level supplies it).
- `sanitizedFilename(_ f: String) -> String`: scalars `< 0x20`, `0x7F`, `/`, `\`, `"` → `_`; strip leading `.`; trim; empty → `"attachment"`.
- `sanitizedMimeType(_ t: String) -> String`: lowercased, trimmed; must be ASCII, contain exactly one `/`, no SP/`;`/`"`; otherwise `"application/octet-stream"`; empty → `"application/octet-stream"`.

Algorithm:
```
1. headers: [String] = []
   headers += HeaderFolding.foldAddressList([m.from], fieldName: "From")
   if !m.to.isEmpty: headers += HeaderFolding.foldAddressList(m.to, fieldName: "To")   // module 11 guarantees ≥ 1; omitted defensively when empty
   if !m.cc.isEmpty: headers += HeaderFolding.foldAddressList(m.cc, fieldName: "Cc")
   headers += "Subject: " + RFC2047.encodeIfNeeded(m.subject, firstLineOffset: 9)
   headers += "Date: " + HeaderDate.rfc5322(m.date, timeZone: m.timeZone)
   headers += "Message-ID: " + (MessageIDs.normalize(m.messageID) ?? m.messageID)
   if let irt = m.inReplyTo.flatMap(MessageIDs.normalize): headers += "In-Reply-To: " + irt
   refs = m.references.compactMap(MessageIDs.normalize); if !refs.isEmpty: headers += HeaderFolding.foldMessageIDs(refs, fieldName: "References")
   headers += "MIME-Version: 1.0"
2. altBoundary = boundaries.boundary(kind: "alt")
   textPart = part(headers: ["Content-Type: text/plain; charset=\"UTF-8\"", "Content-Transfer-Encoding: quoted-printable"],
                   body: QuotedPrintable.encode(Data(ensureTrailingCRLF(normalizeCRLF(m.textBody)))))
   htmlPart = part(headers: ["Content-Type: text/html; charset=\"UTF-8\"", "Content-Transfer-Encoding: quoted-printable"],
                   body: QuotedPrintable.encode(Data(ensureTrailingCRLF(normalizeCRLF(m.htmlBody)))))
   altBody = multipart(boundary: altBoundary, parts: [textPart, htmlPart])
3. if m.attachments.isEmpty:                                                    // structure A
       headers += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\""
       body = altBody
   else:                                                                        // structure B
       mixedBoundary = boundaries.boundary(kind: "mixed")
       headers += "Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\""
       parts = [part(headers: ["Content-Type: multipart/alternative; boundary=\"\(altBoundary)\""], body: altBody)]
       for a in m.attachments:
           name = sanitizedFilename(a.filename); mime = sanitizedMimeType(a.mimeType)
           nameParam = RFC2231.encodeFilenameParams(name)                        // filename="…"[; filename*=…]
           asciiName = the value inside the first quoted string of nameParam    // the ASCII fallback
           parts += part(headers: ["Content-Type: \(mime); name=\"\(asciiName)\"",
                                   "Content-Disposition: attachment; " + nameParam + "; size=\(a.data.count)",
                                   "Content-Transfer-Encoding: base64"],
                         body: base64Lines(a.data))
       body = multipart(boundary: mixedBoundary, parts: parts)
4. out = headers.joined(CRLF) + CRLF + CRLF + body + CRLF
   return Data(out)
```
Header values are folded only where stated; the `Content-Type:` line of the fixtures is 79 characters (within the 998 MUST, beyond the 78 SHOULD — accepted, identical to the pinned fixture). No line the builder emits exceeds 998 octets unless a single mailbox or message-id token is itself longer than 996 characters. `MIME-Version` appears exactly once, at the top level only. The two multipart containers carry no `Content-Transfer-Encoding`. Performance: everything is `[UInt8]` appends with `reserveCapacity`; a message with 20 MB of attachments builds in < 2 s on an iPhone 12-class device (no CI gate; §9 has a Linux sanity budget).

Reference inputs that reproduce `Fixtures/mime/reply-all.eml` byte for byte (see §7 `MIMEBuilderTests.testReplyAllByteExact`):
```
OutgoingMessage(
  from: Mailbox(name: "Max Mustermann", addr: "max.mustermann@newtelco.de"),
  to: [Mailbox(name: "Alice Müller", addr: "alice@example.com"), Mailbox(name: nil, addr: "bob@example.com")],
  cc: [Mailbox(name: "Carol Chen", addr: "carol@partner.example")],
  subject: "Re: Angebot für die Erweiterung",
  date: Date(timeIntervalSince1970: 1789113600), timeZone: TimeZone(identifier: "Europe/Berlin")!,   // → +0200 (CEST)
  messageID: "<7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70@newtelco.de>",
  inReplyTo: "<CAF=abc123@mail.example.com>",
  references: ["<older-id@example.com>", "<CAF=abc123@mail.example.com>"],
  textBody: Fixture text of §5.2 (T_REPLY), htmlBody: Fixture html of §5.2 (H_REPLY), attachments: [])
boundaries: .fixed(alt: "=_minimail_alt_7c1e3f2a9b4d4e6f", mixed: "=_minimail_mixed_unused")
```
Forward (`forward-pdf.eml`): `to: [Mailbox(name: "Dave Davis", addr: "dave@newtelco.de")]`, `cc: []`, `subject: "Fwd: Angebot für die Erweiterung"`, `date: Date(timeIntervalSince1970: 1789113900)`, `messageID: "<0F1E2D3C-4B5A-4968-8778-695A4B3C2D1E@newtelco.de>"`, `inReplyTo: nil`, same `references`, `textBody: T_FWD`, `htmlBody: H_FWD`, `attachments: [OutgoingAttachment(filename: "Angebot-2026-09.pdf", mimeType: "application/pdf", data: stub.pdf bytes)]`, boundaries `.fixed(alt: "=_minimail_alt_1a2b3c4d5e6f7a8b", mixed: "=_minimail_mixed_0b1c2d3e4f5a6b7c")`. The Gmail-web variant (`forward-pdf-gmailweb.eml`) is the same with `inReplyTo: "<CAF=abc123@mail.example.com>"`.

### 4.14 `ComposeStyle`

- `Family.css` (exact, `[html-rendering §5.3]`): helvetica `Helvetica, Arial, sans-serif`; arial `Arial, Helvetica, sans-serif`; verdana `Verdana, Geneva, sans-serif`; tahoma `Tahoma, Geneva, sans-serif`; trebuchet `'Trebuchet MS', Helvetica, sans-serif`; georgia `Georgia, 'Times New Roman', serif`; times `'Times New Roman', Times, serif`; courier `'Courier New', Courier, monospace`.
- `inlineCSS` = `"font-family:\(family.css);font-size:\(min(max(sizePx, 12), 18))px;color:\(ComposeStyle.normalizedColorHex(colorHex) ?? "#000000")"`. Default → `font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000`.
- `init(family:sizePx:colorHex:)` stores the clamped size and `normalizedColorHex(colorHex) ?? "#000000"`.
- `isValidColorHex`: exactly 7 characters, first `#`, the other six in `0-9a-f`. `normalizedColorHex`: lowercases, then validates. `"#ABCDEF"` → `"#abcdef"`; `"abcdef"` → nil; `"#abcd"` → nil; `"#GGGGGG"` → nil.
- `init(from decoder:)`: `container.decodeIfPresent` for each key (`family`, `sizePx`, `colorHex`); a `Family` that fails to decode (unknown raw value) → `.helvetica` (use `try? container.decodeIfPresent(String.self, forKey: .family).flatMap(Family.init(rawValue:))`); `sizePx` clamped; `colorHex` normalised or default. `{}` decodes to the default. `{"family":"comic","sizePx":40,"colorHex":"#ABCDEF"}` → `.helvetica`, 18, `#abcdef`. `encode(to:)` synthesised (keys `family`, `sizePx`, `colorHex`).

### 4.15 `ReplyAll.recipients` (architecture §7.1, verbatim)

```
isSelfReply  = from != nil && me.allAddresses.contains(from.key)
toCandidates = isSelfReply ? to : ((replyTo.isEmpty ? [from].compactMap { $0 } : replyTo) + to)
ccCandidates = cc
seen = Set<String>()
To = toCandidates.filter { !$0.key.isEmpty && !me.allAddresses.contains($0.key) && seen.insert($0.key).inserted }
Cc = ccCandidates.filter { same predicate }                       // To wins over Cc
if To.isEmpty && !Cc.isEmpty { To = Cc; Cc = [] }
if To.isEmpty, let from { To = [from] }                           // note-to-self: never empty To
return Recipients(to: To, cc: Cc)
```
Display names: first-seen wins (a consequence of `filter`); comparison on `key` only. The 16 rows of `[mime-rfc §8.1]` are the contract (§5.4 `reply-all.json`); `me = SelfIdentity(primary: Mailbox(name: "Max Mustermann", addr: "max.mustermann@newtelco.de"), allAddresses: ["m.mustermann@newtelco.de"])`.

### 4.16 `SubjectPrefix`

- `reply(s)`: `t = s.trimmingCharacters(in: .whitespacesAndNewlines)`; return `t.lowercased().hasPrefix("re:") ? t : "Re: " + t`. `""` → `"Re: "`.
- `forward(s)`: same with `"fwd:"` / `"Fwd: "`. `FW: x` → `Fwd: FW: x` (not normalised, `[mime-rfc §1.5]`).
- `stripForDisplay(s)`: loop: `t = trimmed`; lowercase `l = t.lowercased()`; for each prefix `p` in `["re", "fwd", "fw", "aw", "wg"]`: if `l.hasPrefix(p)`, let rest = after `p`; optionally skip `[` digits `]`; require the next character to be `:`; if so `t = after the colon`, continue the outer loop. When no prefix matched, return `t`. `"Re: Fwd: AW: Angebot"` → `"Angebot"`; `"Re[2]: x"` → `"x"`; `"Rewards: x"` → unchanged; `"Re: "` → `""`; `"Fwd:Angebot"` → `"Angebot"`.

### 4.17 `Quoting`

All HTML output uses `OutgoingBodies.escape` for names, subjects and addresses; `{attribution}` = `HeaderDate.attribution(q.date, timeZone:)` (contains U+202F, passed through `escape`, which leaves it untouched).

**4.17.1 attributionLine(author:date:tz)** → `"On \(attribution) \(author.displayName) <\(author.addr)> wrote:"`; `author == nil` → `"On \(attribution) wrote:"`.

**4.17.2 replyHTML(q, tz)** — exact concatenation (one line, no newlines inserted):
```
<div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On {attribution} {AUTHOR_HTML} wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">{BODY_HTML}</blockquote></div>
```
`AUTHOR_HTML` = `{escape(name)} &lt;<a href="mailto:{escape(addr)}">{escape(addr)}</a>&gt;` when `author.name` is non-empty; `&lt;<a href="mailto:{addr}">{addr}</a>&gt;` when the name is nil/empty; when `author == nil` the attribution reads `On {attribution} wrote:<br>` (no author part, single space). `BODY_HTML` = `q.html ?? PlainTextHTML.convert(q.text ?? "")`.

**4.17.3 replyText(q, tz)** → `attributionLine + "\n" + quotedLines` where `quotedLines` = the lines of `sourceText(q)` (line breaks normalised to `\n`, trailing newlines removed) each mapped `line.isEmpty ? ">" : "> " + line`, joined by `"\n"`; when `sourceText` is empty the result is the attribution line alone. `sourceText(q)` = `q.text ?? (q.html.map(textFromHTML) ?? "")`.

**4.17.4 forwardHTML(q, tz)**:
```
<div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>[From: <strong class="gmail_sendername" dir="auto">{escape(name)}</strong> <span dir="auto">&lt;<a href="mailto:{addr}">{addr}</a>&gt;</span><br>]Date: {attribution}<br>Subject: {escape(subject)}<br>To: {TO_HTML}<br>[Cc: {CC_HTML}<br>]</div><br><br>{BODY_HTML}</div>
```
Banner = 10 hyphens, SP, `Forwarded message`, SP, 9 hyphens. The `From:` line is omitted when `author == nil`; when the author has no name the `<strong>` element holds the address and the `<span>` is still emitted. `TO_HTML` / `CC_HTML` = mailboxes mapped to `{escape(name)} &lt;<a href="mailto:{addr}">{addr}</a>&gt;` (nameless: `&lt;<a href="mailto:{addr}">{addr}</a>&gt;`) joined with `", "`; the `Cc:` line is omitted when `q.cc` is empty; `To:` is emitted even when empty (`To: <br>`). `BODY_HTML` as in 4.17.2.

**4.17.5 forwardText(q, tz)**:
```
---------- Forwarded message ---------
[From: {name <addr> | addr}]
Date: {attribution}
Subject: {subject}
To: {to joined ", " as "name <addr>" or "addr"}
[Cc: {cc joined}]


{sourceText(q)}
```
Lines joined with `"\n"`; exactly two empty lines between the header block and the body (`[mime-rfc §4.2]`); no trailing newline; when `sourceText` is empty the result ends after the two empty lines are dropped (i.e. ends with the last header line).

**4.17.6 textFromHTML(html)** — scalar scanner, no regex:
1. Normalise line breaks in the input to `\n`, then replace every run of whitespace (SP, TAB, `\n`) with one SP (HTML whitespace collapsing).
2. Remove `<!-- … -->` comments and the complete elements `<script…>…</script>`, `<style…>…</style>`, `<head…>…</head>` (tag names case-insensitive; unclosed → to end of input).
3. Walk tags: `<br>`, `<br/>`, `<br …>` → `\n`; closing `</p>`, `</div>`, `</li>`, `</tr>`, `</h1>`…`</h6>`, `</blockquote>`, `</pre>`, `</table>` → `\n`; opening `<li>` → `"- "`; opening `<p>`, `<div>`, `<tr>`, `<h1>`…`<h6>`, `<blockquote>`, `<pre>`, `<table>` preceded by non-`\n` text → `\n`; every other tag → removed.
4. Decode entities: `&amp; &lt; &gt; &quot; &apos; &#39; &nbsp;` (→ SP) and numeric `&#NNN;` / `&#xHH;` (invalid → literal); unknown named entities kept literally.
5. Trim SP/TAB at both ends of every line; collapse 3+ consecutive `\n` to 2; trim leading/trailing `\n`.

`<div>Hallo Max,<div><br></div><div>ist das Angebot?</div></div>` → `"Hallo Max,\n\nist das Angebot?"`; `<p>a &amp; b</p><p>c</p>` → `"a & b\nc"`; `<style>p{}</style>x<script>1</script>` → `"x"`; `<div style="x">Max Mustermann<br>newtelco GmbH<br><a href="https://www.newtelco.de">www.newtelco.de</a></div>` → `"Max Mustermann\nnewtelco GmbH\nwww.newtelco.de"`.

### 4.18 `OutgoingBodies`

**escape(s)**: four replacements, `&` first.

**html(typed:style:signatureHTML:quoteHTML:)** — exact concatenation:
1. `lines` = `typed` with `\r\n` and `\r` → `\n`, split on `\n` (an empty `typed` yields one empty line). Each line → `line.trimmingCharacters(in: .whitespaces).isEmpty ? "<div><br></div>" : "<div>\(escape(line))</div>"`.
2. `out = "<div dir=\"ltr\" class=\"minimail_default\" style=\"\(style.inlineCSS)\">" + lines.joined() + "</div>"`.
3. If `signatureHTML` (trimmed) is non-empty: `out += "<div><br></div><span class=\"gmail_signature_prefix\">-- </span><br><div dir=\"ltr\" class=\"gmail_signature\" data-smartmail=\"gmail_signature\"><div style=\"\(style.inlineCSS)\">\(signatureHTML)</div></div>"` (signature inserted verbatim — module 13 sanitised it on save).
4. If `quoteHTML != nil`: `out += "<br>" + quoteHTML`.
5. Return `out`.

Example: `typed = "Hi <Bob>\n\nBye"`, default style, no signature, no quote → `<div dir="ltr" class="minimail_default" style="font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000"><div>Hi &lt;Bob&gt;</div><div><br></div><div>Bye</div></div>`.

**document(bodyFragment)** → `"<html><head><meta charset=\"utf-8\"></head><body>" + bodyFragment + "</body></html>"` — no `<meta name="color-scheme">`, no `<title>`, no `<!DOCTYPE>` (`[html-rendering §5.5]`).

**text(typed:signatureText:quoteText:)**:
```
t = typed with line breaks normalised to "\n", trailing "\n"s removed
parts = [t]
if let s = signatureText?.trimmingTrailingNewlines, !s.isEmpty: parts += ["", "-- ", s]       // "-- " keeps its trailing space
if let q = quoteText, !q.isEmpty: parts += ["", q]
return parts.joined("\n")
```
`typed = "Hallo Alice,\n\nja.\n\nViele Grüße\nMax"`, sig `"Max Mustermann\nnewtelco GmbH"`, quote `"On … wrote:\n> Hallo"` → `"Hallo Alice,\n\nja.\n\nViele Grüße\nMax\n\n-- \nMax Mustermann\nnewtelco GmbH\n\nOn … wrote:\n> Hallo"`.

### 4.19 `PlainTextHTML.convert(text)`

1. Normalise line breaks to `\n`; split into lines (empty input → one empty line).
2. Per line: if the line is empty (after removing SP/TAB) → `<div><br></div>`; else split the line into runs separated by SP/TAB, keeping the separators; for each run `w`:
   - `lead` = longest prefix of `w` consisting of `(`, `<`, `[`, `"`, `'`; `core0 = w` without `lead`.
   - if `core0.lowercased()` has prefix `http://`, `https://` or `www.`: `trail` = longest suffix of `core0` made of `.`, `,`, `;`, `:`, `!`, `?`, `)`, `]`, `}`, `>`, `"`, `'`; `core = core0` without `trail`; if `core.count > prefix.count`: `href = core.lowercased().hasPrefix("www.") ? "http://" + core : core`; emit `escape(lead) + "<a href=\"\(escape(href))\">\(escape(core))</a>" + escape(trail)`; else emit `escape(w)`.
   - otherwise emit `escape(w)`.
   - separators are emitted escaped (unchanged).
   - line → `"<div>" + joined + "</div>"`.
3. Return `"<div class=\"mm-plaintext\">" + lines.joined() + "</div>"`.

Examples: `"see https://x.com/a?b=1&c=2."` → `<div class="mm-plaintext"><div>see <a href="https://x.com/a?b=1&amp;c=2">https://x.com/a?b=1&amp;c=2</a>.</div></div>`; `"(www.newtelco.de)"` → `<div class="mm-plaintext"><div>(<a href="http://www.newtelco.de">www.newtelco.de</a>)</div></div>`; `"a < b\n\nc"` → `<div class="mm-plaintext"><div>a &lt; b</div><div><br></div><div>c</div></div>`; `""` → `<div class="mm-plaintext"><div><br></div></div>`.

### 4.20 Concurrency, isolation, performance

Every function is a nonisolated pure `static func` on Sendable value types; callers in the app (`Outbox` actor, `ComposeModel` on the main actor, `SyncEngine` actor) invoke them without hopping. No function allocates more than O(n) in the input size. Budgets (informational, measured by `swift test` timing on Linux, no CI gate): `QuotedPrintable.encode` of 1 MB ≤ 50 ms; `MIMEBuilder.build` with one 5 MB attachment ≤ 300 ms; `AddressParser.parseList` of 200 mailboxes ≤ 5 ms; `RFC2047.decode` of a 1 KB header ≤ 1 ms.

---

## 5. Data

### 5.1 MIME fixtures (`Tests/MailCoreTests/Fixtures/mime/`)

Create the three `.eml` files with CRLF line endings from the research text; verify the hashes. Run from the repo root on Linux (python3 present):

```sh
python3 - <<'EOF'
import hashlib, base64, pathlib
src = pathlib.Path('docs/plan/research/mime-rfc.md').read_text(encoding='utf-8').split('\n')
out = pathlib.Path('Packages/MailCore/Tests/MailCoreTests/Fixtures/mime'); out.mkdir(parents=True, exist_ok=True)
def crlf(a, b): return ('\r\n'.join(src[a-1:b]) + '\r\n').encode('utf-8')
reply = crlf(379, 435); fwd = crlf(449, 517)
lines = src[449-1:456]; i = next(k for k, l in enumerate(lines) if l.startswith('Message-ID:'))
gmailweb = ('\r\n'.join(lines[:i+1] + ['In-Reply-To: <CAF=abc123@mail.example.com>'] + lines[i+1:])).encode() + b'\r\n\r\n' + fwd.split(b'\r\n\r\n', 1)[1]
pdf = b'%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n'
for name, data in (('reply-all', reply), ('forward-pdf', fwd), ('forward-pdf-gmailweb', gmailweb)):
    (out / f'{name}.eml').write_bytes(data)
    (out / f'{name}.sha256').write_text(hashlib.sha256(data).hexdigest() + '  ' + name + '.eml\n')
(out / 'reply-all.raw.txt').write_text(src[441-1].strip() + '\n')
(out / 'forward-pdf.raw.txt').write_text(src[521-1].strip() + '\n')
(out / 'stub.pdf').write_bytes(pdf)
print(len(reply), hashlib.sha256(reply).hexdigest()); print(len(fwd), hashlib.sha256(fwd).hexdigest()); print(len(gmailweb), hashlib.sha256(gmailweb).hexdigest())
assert base64.urlsafe_b64decode(src[441-1].strip() + '=') == reply and base64.urlsafe_b64decode(src[521-1].strip() + '=') == fwd
EOF
cd Packages/MailCore/Tests/MailCoreTests/Fixtures/mime && sha256sum -c reply-all.sha256 forward-pdf.sha256 forward-pdf-gmailweb.sha256
```
Expected output: `2276 b9f8078c1d50352b00f1486624bb2247ec19587ccf388b652aed62da0d1fcbd3`, `2927 2127dc5426a76d3deb405f04f30b602d22461af3b8ea6dbdee8d494d66429261`, `2971 d8dc2b8522a8354d8cb0709757660d1ddea87f342d75a23752bb619cf9e74d86`, three `OK` lines. (The first two hashes are the research's own; the third was derived while writing this spec by the same construction and is re-verified by `sha256sum -c`.) `stub.pdf` is 125 bytes, sha256 `79370862c6cb54e96ed3125464c11e4ce3e8b08fb5048723695b6b9e9728d701`.

The CRLF bytes must survive git: this module adds `Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/.gitattributes` with exactly these three lines — `*.eml -text`, `*.raw.txt -text`, `*.pdf binary` — so no checkout converts line endings (created in task T2.6; listed in §2).

### 5.2 Body strings used by the byte-exact tests (Swift string literals inside `MIMEBuilderTests.swift`)

To keep the trailing space of the `-- ` line safe from editors and `swift format`, `MIMEBuilderTests` builds `textReply` programmatically: `["Hallo Alice,", "", "ja, das Angebot geht heute noch raus.", "", "Viele Grüße", "Max", "", "-- ", "Max Mustermann", "newtelco GmbH", "https://www.newtelco.de", "", "On Thu, Sep 10, 2026 at 9:12\u{202F}AM Alice Müller <alice@example.com> wrote:", "> Hallo Max,", ">", "> ist das Angebot für die Erweiterung schon unterwegs?", ">", "> Gruß", "> Alice", ""].joined(separator: "\n")` (the final empty element yields the trailing newline).

```swift
static let htmlReply = "<div dir=\"ltr\" style=\"font-family:Helvetica,Arial,sans-serif;font-size:14px;color:#1d1d1f\">Hallo Alice,<div><br></div><div>ja, das Angebot geht heute noch raus.</div><div><br></div><div>Viele Grüße<br>Max</div><div><br></div><span class=\"gmail_signature_prefix\">-- </span><br><div class=\"gmail_signature\"><div style=\"font-family:Helvetica,Arial,sans-serif;font-size:13px;color:#222222\">Max Mustermann<br>newtelco GmbH<br><a href=\"https://www.newtelco.de\">www.newtelco.de</a></div></div></div><br><div class=\"gmail_quote gmail_quote_container\"><div dir=\"ltr\" class=\"gmail_attr\">On Thu, Sep 10, 2026 at 9:12\u{202F}AM Alice Müller &lt;<a href=\"mailto:alice@example.com\">alice@example.com</a>&gt; wrote:<br></div><blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\"><div dir=\"ltr\">Hallo Max,<div><br></div><div>ist das Angebot für die Erweiterung schon unterwegs?</div><div><br></div><div>Gruß<br>Alice</div></div></blockquote></div>"
// no trailing newline; the builder appends CRLF

static let textForward = ["FYI, siehe Anhang.", "", "-- ", "Max Mustermann", "newtelco GmbH", "https://www.newtelco.de", "", "---------- Forwarded message ---------", "From: Alice Müller <alice@example.com>", "Date: Thu, Sep 10, 2026 at 9:12\u{202F}AM", "Subject: Angebot für die Erweiterung", "To: Max Mustermann <max.mustermann@newtelco.de>", "Cc: Carol Chen <carol@partner.example>", "", "", "Hallo Max,", "", "ist das Angebot für die Erweiterung schon unterwegs?", "", "Gruß", "Alice", ""].joined(separator: "\n")

static let htmlForward = "<div dir=\"ltr\" style=\"font-family:Helvetica,Arial,sans-serif;font-size:14px;color:#1d1d1f\">FYI, siehe Anhang.<div><br></div><span class=\"gmail_signature_prefix\">-- </span><br><div class=\"gmail_signature\"><div style=\"font-family:Helvetica,Arial,sans-serif;font-size:13px;color:#222222\">Max Mustermann<br>newtelco GmbH<br><a href=\"https://www.newtelco.de\">www.newtelco.de</a></div></div></div><br><div class=\"gmail_quote gmail_quote_container\"><div dir=\"ltr\" class=\"gmail_attr\">---------- Forwarded message ---------<br>From: <strong class=\"gmail_sendername\" dir=\"auto\">Alice Müller</strong> <span dir=\"auto\">&lt;<a href=\"mailto:alice@example.com\">alice@example.com</a>&gt;</span><br>Date: Thu, Sep 10, 2026 at 9:12\u{202F}AM<br>Subject: Angebot für die Erweiterung<br>To: Max Mustermann &lt;<a href=\"mailto:max.mustermann@newtelco.de\">max.mustermann@newtelco.de</a>&gt;<br>Cc: Carol Chen &lt;<a href=\"mailto:carol@partner.example\">carol@partner.example</a>&gt;<br></div><br><br><div dir=\"ltr\">Hallo Max,<div><br></div><div>ist das Angebot für die Erweiterung schon unterwegs?</div><div><br></div><div>Gruß<br>Alice</div></div></div>"
```
These literals are the decoded QP parts of the fixtures (verified: re-encoding them with the §4.2 algorithm reproduces the fixture bytes exactly). The fixture HTML uses `font-family:Helvetica,Arial,sans-serif` (no spaces) and bare fragments (no `<html>` wrapper) — they pin `MIMEBuilder`, not `OutgoingBodies`.

### 5.3 `Charsets` alias table (lowercased IANA name → `String.Encoding`)

| Names | Encoding |
|---|---|
| `utf-8`, `utf8` | `.utf8` |
| `us-ascii`, `ascii`, `ansi_x3.4-1968`, `iso646-us`, `us` | `.ascii` |
| `iso-8859-1`, `iso8859-1`, `iso_8859-1`, `latin1`, `l1`, `cp819`, `ibm819` | `.isoLatin1` |
| `iso-8859-2`, `iso8859-2`, `iso_8859-2`, `latin2`, `l2` | `.isoLatin2` |
| `iso-8859-15`, `iso8859-15`, `iso_8859-15`, `latin9`, `latin-9`, `l9` | `String.Encoding(rawValue: 0x8000_020F)` |
| `windows-1250`, `cp1250` | `.windowsCP1250` |
| `windows-1251`, `cp1251` | `.windowsCP1251` |
| `windows-1252`, `cp1252`, `x-cp1252` | `.windowsCP1252` |
| `windows-1253`, `cp1253` | `.windowsCP1253` |
| `windows-1254`, `cp1254` | `.windowsCP1254` |
| `koi8-r`, `koi8r` | `String.Encoding(rawValue: 0x8000_0A02)` |
| `shift_jis`, `shift-jis`, `sjis`, `x-sjis`, `ms_kanji`, `cp932`, `windows-31j` | `.shiftJIS` |
| `euc-jp`, `eucjp`, `x-euc-jp` | `.japaneseEUC` |
| `iso-2022-jp`, `csiso2022jp` | `.iso2022JP` |
| `gb2312`, `gb_2312-80`, `csgb2312`, `euc-cn`, `x-euc-cn` | `String.Encoding(rawValue: 0x8000_0630)` |
| `gbk`, `cp936`, `ms936`, `windows-936` | `String.Encoding(rawValue: 0x8000_0631)` |
| `gb18030` | `String.Encoding(rawValue: 0x8000_0632)` |
| `big5`, `big-5`, `csbig5`, `cp950`, `big5-hkscs` | `String.Encoding(rawValue: 0x8000_0A03)` |
| `euc-kr`, `ks_c_5601-1987`, `cp949` | `String.Encoding(rawValue: 0x8000_0940)` |
| `utf-16`, `utf16` | `.utf16` |
| `utf-16be` | `.utf16BigEndian` |
| `utf-16le` | `.utf16LittleEndian` |
| `macintosh`, `x-mac-roman` | `.macOSRoman` |

The `0x8000_xxxx` raw values follow the documented Foundation convention `NSStringEncoding = 0x80000000 | CFStringEncoding` for encodings without an `NS*` constant (`kCFStringEncodingISOLatin9 = 0x020F`, `KOI8_R = 0x0A02`, `GB_2312_80 = 0x0630`, `GBK_95 = 0x0631`, `GB_18030_2000 = 0x0632`, `Big5 = 0x0A03`, `EUC_KR = 0x0940`) — UNVERIFIED against Apple documentation in this session (blocked, `[mime-rfc §9, §10 item 5]`); the Darwin-only tests of §7 confirm them at first `make core-test` on macOS, and a wrong value only means the decode chain falls through to UTF-8/Latin-1.

### 5.4 Vector files (`Tests/MailCoreTests/Fixtures/vectors/`, UTF-8 JSON, exact contents)

`qp.json` — `[{"input": String, "output": String}]`; `\r\n` written as JSON escapes; the 80-x row uses the literal 80 `x` characters:
```json
[
  {"input": "Grüße", "output": "Gr=C3=BC=C3=9Fe"},
  {"input": "a=b", "output": "a=3Db"},
  {"input": "trailing space ", "output": "trailing space=20"},
  {"input": "tab\tend\t", "output": "tab\tend=09"},
  {"input": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "output": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=\r\nxxxxx"},
  {"input": "Viele Grüße\r\nMax", "output": "Viele Gr=C3=BC=C3=9Fe\r\nMax"},
  {"input": "-- ", "output": "--=20"}
]
```

`rfc2047.json` — `[{"input": String, "output": String}]`:
```json
[
  {"input": "=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?=", "output": "Alice Müller"},
  {"input": "=?utf-8?q?Gr=C3=BC=C3=9Fe_aus_K=C3=B6ln?=", "output": "Grüße aus Köln"},
  {"input": "=?UTF-8?Q?a?= =?UTF-8?Q?b?=", "output": "ab"},
  {"input": "=?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?=", "output": "Keld Jørn Simonsen"},
  {"input": "plain =?UTF-8?B?w6TDtsO8?= end", "output": "plain äöü end"},
  {"input": "=?UTF-8?B?4pyT?= ok", "output": "✓ ok"},
  {"input": "=?utf-8?B?SGk=?=\r\n =?utf-8?B?IHRoZXJl?=", "output": "Hi there"},
  {"input": "=?UTF-8?B?w6Q?=", "output": "ä"},
  {"input": "=?X-UNKNOWN?Q?abc?=", "output": "=?X-UNKNOWN?Q?abc?="}
]
```

`base64.json` — `[{"hex": String, "base64": String, "base64url": String}]` (`base64url` unpadded):
```json
[
  {"hex": "", "base64": "", "base64url": ""},
  {"hex": "66", "base64": "Zg==", "base64url": "Zg"},
  {"hex": "666f", "base64": "Zm8=", "base64url": "Zm8"},
  {"hex": "666f6f", "base64": "Zm9v", "base64url": "Zm9v"},
  {"hex": "fbffbf", "base64": "+/+/", "base64url": "-_-_"},
  {"hex": "00112233445566778899aabbccddeeff", "base64": "ABEiM0RVZneImaq7zN3u/w==", "base64url": "ABEiM0RVZneImaq7zN3u_w"}
]
```

`rfc2231.json` — `[{"contentDisposition": String, "filename": String}]`:
```json
[
  {"contentDisposition": "attachment; filename=\"Angebot.pdf\"", "filename": "Angebot.pdf"},
  {"contentDisposition": "attachment; filename*=utf-8''%C3%84ngebot%202026.pdf", "filename": "Ängebot 2026.pdf"},
  {"contentDisposition": "attachment; filename*=UTF-8'de'%C3%84ngebot.pdf", "filename": "Ängebot.pdf"},
  {"contentDisposition": "attachment; filename*0*=utf-8''%C3%84nge; filename*1*=bot; filename*2=\".pdf\"", "filename": "Ängebot.pdf"},
  {"contentDisposition": "attachment; filename=\"fallback.pdf\"; filename*=utf-8''%C3%84ngebot.pdf", "filename": "Ängebot.pdf"},
  {"contentDisposition": "attachment; filename=\"=?UTF-8?B?w4RuZ2Vib3QucGRm?=\"", "filename": "Ängebot.pdf"}
]
```

`addresses.json` — `[{"input": String, "output": [{"name": String|null, "addr": String}]}]`:
```json
[
  {"input": "\"Müller, Alice\" <alice@example.com>, bob@example.com", "output": [{"name": "Müller, Alice", "addr": "alice@example.com"}, {"name": null, "addr": "bob@example.com"}]},
  {"input": "Alice (Sales) <alice@example.com>", "output": [{"name": "Alice", "addr": "alice@example.com"}]},
  {"input": "=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?= <alice@example.com>", "output": [{"name": "Alice Müller", "addr": "alice@example.com"}]},
  {"input": "Team: alice@example.com, bob@example.com;", "output": [{"name": null, "addr": "alice@example.com"}, {"name": null, "addr": "bob@example.com"}]},
  {"input": "alice@example.com (Alice)", "output": [{"name": "Alice", "addr": "alice@example.com"}]},
  {"input": "\"Bob \\\"The Builder\\\"\" <bob@example.com>", "output": [{"name": "Bob \"The Builder\"", "addr": "bob@example.com"}]},
  {"input": "Alice <Alice@Example.COM>", "output": [{"name": "Alice", "addr": "Alice@Example.COM"}]},
  {"input": "<alice@example.com>", "output": [{"name": null, "addr": "alice@example.com"}]},
  {"input": "alice@example.com", "output": [{"name": null, "addr": "alice@example.com"}]},
  {"input": "Alice\r\n <alice@example.com>", "output": [{"name": "Alice", "addr": "alice@example.com"}]},
  {"input": "undisclosed-recipients:;", "output": []},
  {"input": "bob@example.com,, ,carol@partner.example", "output": [{"name": null, "addr": "bob@example.com"}, {"name": null, "addr": "carol@partner.example"}]},
  {"input": "Bob <@relay.example:bob@example.com>", "output": [{"name": "Bob", "addr": "bob@example.com"}]},
  {"input": "\"Alice (Sales)\" <alice@example.com>", "output": [{"name": "Alice (Sales)", "addr": "alice@example.com"}]},
  {"input": "", "output": []}
]
```

`reply-all.json` — `[{"id": Int, "from": String, "replyTo": String, "to": String, "cc": String, "expectedTo": String, "expectedCc": String}]`; every field is a header value parsed with `AddressParser.parseList` (empty string → `[]`); the 16 rows of `[mime-rfc §8.1]`:
```json
[
  {"id": 1, "from": "Alice <alice@example.com>", "replyTo": "", "to": "max.mustermann@newtelco.de", "cc": "", "expectedTo": "Alice <alice@example.com>", "expectedCc": ""},
  {"id": 2, "from": "Alice <alice@example.com>", "replyTo": "", "to": "Max <max.mustermann@newtelco.de>, Bob <bob@example.com>", "cc": "carol@partner.example", "expectedTo": "Alice <alice@example.com>, Bob <bob@example.com>", "expectedCc": "carol@partner.example"},
  {"id": 3, "from": "Alice <alice@example.com>", "replyTo": "Support <support@example.com>", "to": "max.mustermann@newtelco.de, bob@example.com", "cc": "", "expectedTo": "Support <support@example.com>, bob@example.com", "expectedCc": ""},
  {"id": 4, "from": "alice@example.com", "replyTo": "", "to": "MAX.MUSTERMANN@newtelco.de, Bob <bob@example.com>", "cc": "M.Mustermann@NewTelco.de, dave@newtelco.de", "expectedTo": "alice@example.com, Bob <bob@example.com>", "expectedCc": "dave@newtelco.de"},
  {"id": 5, "from": "Alice <alice@example.com>", "replyTo": "", "to": "bob@example.com", "cc": "Alice <alice@example.com>, bob@example.com", "expectedTo": "Alice <alice@example.com>, bob@example.com", "expectedCc": ""},
  {"id": 6, "from": "Alice <alice@example.com>", "replyTo": "alice@example.com, list@example.com", "to": "max.mustermann@newtelco.de", "cc": "", "expectedTo": "alice@example.com, list@example.com", "expectedCc": ""},
  {"id": 7, "from": "\"Müller, Alice\" <alice@example.com>", "replyTo": "", "to": "max.mustermann@newtelco.de", "cc": "", "expectedTo": "\"Müller, Alice\" <alice@example.com>", "expectedCc": ""},
  {"id": 8, "from": "=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?= <alice@example.com>", "replyTo": "", "to": "max.mustermann@newtelco.de", "cc": "", "expectedTo": "Alice Müller <alice@example.com>", "expectedCc": ""},
  {"id": 9, "from": "Max Mustermann <max.mustermann@newtelco.de>", "replyTo": "", "to": "Alice <alice@example.com>, bob@example.com", "cc": "carol@partner.example", "expectedTo": "Alice <alice@example.com>, bob@example.com", "expectedCc": "carol@partner.example"},
  {"id": 10, "from": "Max <max.mustermann@newtelco.de>", "replyTo": "list@example.com", "to": "alice@example.com", "cc": "", "expectedTo": "alice@example.com", "expectedCc": ""},
  {"id": 11, "from": "Alice <alice@example.com>", "replyTo": "", "to": "Team: max.mustermann@newtelco.de, bob@example.com;", "cc": "", "expectedTo": "Alice <alice@example.com>, bob@example.com", "expectedCc": ""},
  {"id": 12, "from": "alice@example.com (Alice)", "replyTo": "", "to": "undisclosed-recipients:;", "cc": "", "expectedTo": "Alice <alice@example.com>", "expectedCc": ""},
  {"id": 13, "from": "Alice <alice@example.com>", "replyTo": "", "to": "max.mustermann@newtelco.de", "cc": "max.mustermann@newtelco.de", "expectedTo": "Alice <alice@example.com>", "expectedCc": ""},
  {"id": 14, "from": "Max <max.mustermann@newtelco.de>", "replyTo": "", "to": "max.mustermann@newtelco.de", "cc": "", "expectedTo": "Max <max.mustermann@newtelco.de>", "expectedCc": ""},
  {"id": 15, "from": "Alice <alice@example.com>", "replyTo": "", "to": "bob@example.com,, ,carol@partner.example", "cc": "", "expectedTo": "Alice <alice@example.com>, bob@example.com, carol@partner.example", "expectedCc": ""},
  {"id": 16, "from": "Alice <alice@example.com>", "replyTo": "", "to": "Bob <@relay.example:bob@example.com>", "cc": "", "expectedTo": "Alice <alice@example.com>, Bob <bob@example.com>", "expectedCc": ""}
]
```
Row 7 additionally asserts `Mailbox.serialized()` of the first To entry equals `=?UTF-8?B?TcO8bGxlciwgQWxpY2U=?= <alice@example.com>`.

`subject.json` — `[{"original": String, "reply": String, "forward": String}]` (`[mime-rfc §8.2]`, the RFC 2047 row decoded first):
```json
[
  {"original": "Angebot", "reply": "Re: Angebot", "forward": "Fwd: Angebot"},
  {"original": "Re: Angebot", "reply": "Re: Angebot", "forward": "Fwd: Re: Angebot"},
  {"original": "RE: Angebot", "reply": "RE: Angebot", "forward": "Fwd: RE: Angebot"},
  {"original": "Fwd: Angebot", "reply": "Re: Fwd: Angebot", "forward": "Fwd: Angebot"},
  {"original": "FW: Angebot", "reply": "Re: FW: Angebot", "forward": "Fwd: FW: Angebot"},
  {"original": "", "reply": "Re: ", "forward": "Fwd: "},
  {"original": "Angebot für die Erweiterung", "reply": "Re: Angebot für die Erweiterung", "forward": "Fwd: Angebot für die Erweiterung"}
]
```
The last row additionally asserts `RFC2047.encodeIfNeeded(reply, firstLineOffset: 9) == "=?UTF-8?B?UmU6IEFuZ2Vib3QgZsO8ciBkaWUgRXJ3ZWl0ZXJ1bmc=?="` and `RFC2047.encodeIfNeeded(forward, firstLineOffset: 9) == "=?UTF-8?B?RndkOiBBbmdlYm90IGbDvHIgZGllIEVyd2VpdGVydW5n?="`.

### 5.5 Codable shapes produced by this module

- `Mailbox` JSON: `{"name":"Alice Müller","addr":"alice@example.com"}`; `name` absent/`null` when nil (synthesised Codable).
- `ComposeStyle` JSON: `{"colorHex":"#000000","family":"helvetica","sizePx":14}` (module 01's `SettingsStore` encodes with `.sortedKeys`).
- `QuoteSource` JSON (synthesised; `date` uses the encoder's date strategy — module 07 and 11 must configure the same `JSONEncoder`/`JSONDecoder`; the default `.deferredToDate` yields a number of seconds since 2001-01-01; 1789024353 − 978307200 = 810717153): `{"author":{"addr":"alice@example.com","name":"Alice Müller"},"cc":[],"date":810717153,"html":"<div>…</div>","subject":"Angebot","text":"…","to":[{"addr":"max.mustermann@newtelco.de","name":"Max Mustermann"}]}`.
- `ComposeMode` JSON: `"replyAll"` / `"forward"`.

No Info.plist keys, no SQL, no config values belong to this module.

---

## 6. UI

Not applicable — this module has no screens. (`ComposeStyle.Family.displayName` supplies the picker labels for module 13; nothing else is user-visible.)

---

## 7. Tests

All tests: XCTest, target `MailCoreTests`, run with `cd Packages/MailCore && swift test` (Linux and macOS; `make core-test`). Fixture loading via `Fixture` (§3.20). Every table-driven test iterates the JSON rows and reports the failing row with `XCTAssertEqual(actual, expected, "row \(i): \(input)")`. Tests marked *Darwin only* are wrapped in `#if canImport(Darwin)`; tests marked *skip-if-unsupported* call `try XCTSkipIf(String(data: sample, encoding: enc) == nil, "encoding unsupported on this platform")`.

| Test file | Test function | Setup | Assertions |
|---|---|---|---|
| `Base64URLTests.swift` | `testVectorsEncode` | `vectors/base64.json`; hex → `Data` | `Base64URL.encode(data) == base64url + padding` where padding = `""`/`"="`/`"=="` making the length a multiple of 4; `encode(Data())== ""` |
| | `testVectorsDecodeUnpaddedURL` | same rows | `decode(base64url) == data` |
| | `testVectorsDecodePaddedStandard` | same rows | `decode(base64) == data` |
| | `testDecodeRejectsGarbage` | — | `decode("Zg=x") == nil`, `decode("Z g") == nil`, `decode("Zg=") == Data([0x66])`, `decode("Z") == nil`, `decode("ZZ==Z") == nil` |
| | `testRawFixtureRoundTrip` | `mime/reply-all.eml`, `mime/reply-all.raw.txt` (trimmed) | `decode(raw) == eml`; `encode(eml) == raw + "="`; `encode(eml).count == 3036`; same for `forward-pdf` (`3904`) |
| `QuotedPrintableTests.swift` | `testEncodeVectors` | `vectors/qp.json` | `String(decoding: QuotedPrintable.encode(Data(input.utf8)), as: UTF8.self) == output` for all 7 rows |
| | `testEncodeLineLengthAndNoSplitEscape` | 300 × `ä` (2 bytes each) with CRLF every 100 chars | every output line ≤ 76 bytes; no line ends with `=` followed by one hex digit; decode(encode(x)) == x |
| | `testDecodeTolerant` | inputs `"a=3db"`, `"a=\r\nb"`, `"a=\nb"`, `"a =\r\n"`, `"x \t\r\ny"`, `"=ZZ"`, `"trail= "` | outputs `"a=b"`, `"ab"`, `"ab"`, `"a"`, `"x\r\ny"`, `"=ZZ"`, `"trail="` |
| | `testRoundTripFixtureParts` | `htmlReply` from §5.2 | `decode(encode(Data((htmlReply + "\r\n").utf8))) == Data((htmlReply + "\r\n").utf8)` |
| `RFC2047Tests.swift` | `testDecodeVectors` | `vectors/rfc2047.json` | `RFC2047.decode(input) == output` for all 9 rows |
| | `testEncodePassthrough` | `"Re: Invoice 42"`, `""`, 900 × `a` | returned unchanged |
| | `testEncodeSingleWord` | `"Re: Angebot für die Erweiterung"` offset 9; `"Alice Müller"` offset 0 | `"=?UTF-8?B?UmU6IEFuZ2Vib3QgZsO8ciBkaWUgRXJ3ZWl0ZXJ1bmc=?="`; `"=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?="` |
| | `testEncodeChunksAndFolds` | `"ÄÖÜäöüß" × 4` offset 9; `"ä" × 100` offset 0 | result contains `"\r\n "`; every line ≤ 76 chars; every word ≤ 75 chars; `decode(result) == input`; no word's base64 decodes to bytes that end inside a UTF-8 sequence (decode each word's bytes as UTF-8 succeeds) |
| | `testEncodeControlCharsAndLong` | `"a\u{07}b"`; 901 × `a` | both encoded (start with `=?UTF-8?B?`) and round-trip through `decode` |
| `RFC2231Tests.swift` | `testFilenameVectors` | `vectors/rfc2231.json` → `ContentTypeParams.parse` | `RFC2231.parameter(named: "filename", in: ct.params) == filename` for all 6 rows; `named: "FILENAME"` gives the same |
| | `testParameterAbsent` | `attachment; size=3` | `parameter(named: "filename", …) == nil` |
| | `testEncodeFilenameParams` | `"Ängebot.pdf"`, `"Angebot 2026.pdf"`, `"we\"ird.pdf"` | `filename="_ngebot.pdf"; filename*=UTF-8''%C3%84ngebot.pdf`; `filename="Angebot 2026.pdf"`; `filename="we\"ird.pdf"; filename*=UTF-8''we%22ird.pdf` |
| `CharsetsTests.swift` | `testAliasTable` | names `"UTF-8"`, `" utf8 "`, `"\"iso-8859-1\""`, `"latin1"`, `"Windows-1252"`, `"cp1252"`, `"us-ascii"`, `"UTF-8*de"`, `"shift_jis"`, `"koi8-r"`, `"x-nope"` | `.utf8`, `.utf8`, `.isoLatin1`, `.isoLatin1`, `.windowsCP1252`, `.windowsCP1252`, `.ascii`, `.utf8`, `.shiftJIS`, `String.Encoding(rawValue: 0x8000_0A02)`, nil |
| | `testDecodeChain` | bytes `47 72 FC DF 65` (Latin-1 `Grüße`) with charset `"iso-8859-1"`, `nil`, `"x-nope"`; bytes `47 72 C3 BC C3 9F 65` with `"utf-8"` and `nil`; `EF BB BF 41` with `"utf-8"` | `"Grüße"` (Latin-1); `"Grüße"` (utf8 fails → latin1); `"Grüße"`; `"Grüße"`; `"Grüße"`; `"A"` (BOM stripped) |
| | `testDecodeWindows1252` *skip-if-unsupported* | `47 72 FC DF 65 80` with `"windows-1252"` | `"Grüße€"` |
| | `testDecodeExoticDarwin` *Darwin only* | KOI8-R `F0 F2 C9 D7 C5 D4` → `"Привет"`; ISO-8859-15 `A4` → `"€"`; Shift_JIS `82 B1 82 F1 82 C9 82 BF 82 CD` → `"こんにちは"`; ISO-2022-JP `1B 24 42 24 33 24 73 24 4B 24 41 24 4F 1B 28 42` → `"こんにちは"` | equal |
| `MailboxTests.swift` | `testKeyAndDisplayName` | `Mailbox(name: nil, addr: "Alice@Example.COM")` | `key == "alice@example.com"`, `displayName == "Alice@Example.COM"`; with name `"Alice"` → `displayName == "Alice"` |
| | `testSerializedForms` | the five examples of §4.6 | exact strings |
| | `testCodableRoundTrip` | `Mailbox(name: "Müller, Alice", addr: "a@b")` via `JSONEncoder`/`JSONDecoder` | equal after round trip; JSON of a nil name has no `"name"` key or `null` |
| `AddressParserTests.swift` | `testVectors` | `vectors/addresses.json` | `parseList(input) == output.map(Mailbox.init)` for all 15 rows |
| | `testParseFirst` | `"a@b, c@d"`, `""` | `Mailbox(name: nil, addr: "a@b")`, nil |
| | `testGarbageDoesNotCrash` | `"<<<>>>"`, `"(((("`, `"\"unterminated"`, `":;:;"`, `"<@:>"` | returns without crashing; every returned mailbox has a non-empty `addr` |
| | `testManyMailboxesFast` | 200 mailboxes joined `", "` | `parseList` returns 200; wall time < 50 ms (`XCTAssertLessThan` on `Date` delta) |
| `HeaderDateTests.swift` | `testRFC5322Format` | `Date(timeIntervalSince1970: 1789113600)` | Europe/Berlin → `"Fri, 11 Sep 2026 10:00:00 +0200"`; UTC → `"Fri, 11 Sep 2026 08:00:00 +0000"`; `Date(timeIntervalSince1970: 0)` UTC → `"Thu, 1 Jan 1970 00:00:00 +0000"` |
| | `testAttribution` | `Date(timeIntervalSince1970: 1789024353)` Europe/Berlin; `1789113600` UTC; `1789128000` UTC (12:00); `1789085100` UTC (00:05) | `"Thu, Sep 10, 2026 at 9:12\u{202F}AM"`; `"Fri, Sep 11, 2026 at 8:00\u{202F}AM"`; `"Fri, Sep 11, 2026 at 12:00\u{202F}PM"`; `"Fri, Sep 11, 2026 at 12:05\u{202F}AM"`; `Array(result.utf8)` contains `[0xE2, 0x80, 0xAF]` |
| | `testParseMatrix` | the 10 rows of §4.8 | `parse(input)?.timeIntervalSince1970 == expected` (nil rows → nil) |
| | `testFormatParseRoundTrip` | 20 dates (`1789113600 + k * 86_400 * 37`), Europe/Berlin | `parse(rfc5322(d, tz)) == d` |
| `HeaderFoldingTests.swift` | `testUnfold` | `"Alice\r\n <a@b>"`, `"a\r\nb"`, `"x\n\ty\r\n"`, `"z\r\n"` | `"Alice <a@b>"`, `"a\r\nb"`, `"x\ty"`, `"z"` |
| | `testFoldAddressListAt78` | 6 mailboxes `Mailbox(name: "Recipient Number N", addr: "recipientN@example.com")` under `"To"` | every line ≤ 78 chars; lines after the first start with SP; joining lines and removing `"\r\n "` gives `"To: " + serialized.joined(", ")`; a single short list stays on one line; `[]` → `"To:"` |
| | `testFoldMessageIDs` | 5 ids of 40 chars; the fixture pair | each line ≤ 78; the fixture pair → `"References: <older-id@example.com> <CAF=abc123@mail.example.com>"` |
| `ContentTypeParamsTests.swift` | `testRows` | the 6 rows of §4.10 | exact `type`, `param(...)` values and `params.count` |
| | `testEquatable` | two equal values, one with different param order | equal / not equal |
| `MessageIDsTests.swift` | `testSplit` | the 5 inputs of §4.11 | exact arrays |
| | `testNormalize` | `" CAF=abc@mail.example.com "`, `"<a@b>"`, `"<x>"`, `""`, `"<a b@c>"`, `"<>"` | `"<CAF=abc@mail.example.com>"`, `"<a@b>"`, `"<x>"`, nil, nil, nil |
| | `testGenerate` | fixed UUID `7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70`, `newtelco.de`; empty domain | `"<7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70@newtelco.de>"`; `hasSuffix("@localhost>")` |
| | `testReferencesChain` | the 6 cases of §4.11 | exact arrays |
| `MIMEBuilderTests.swift` | `testReplyAllByteExact` | inputs of §4.13 (reply), `.fixed` boundaries | `build(...) == Fixture.data("mime/reply-all.eml")`; `.count == 2276`; on mismatch the test prints the first differing byte offset and the surrounding 40 bytes of both |
| | `testForwardByteExact` | inputs of §4.13 (forward), `stub.pdf` from fixtures | `== Fixture.data("mime/forward-pdf.eml")`; `.count == 2927` |
| | `testForwardGmailWebVariantByteExact` | same with `inReplyTo` set | `== Fixture.data("mime/forward-pdf-gmailweb.eml")`; `.count == 2971` |
| | `testStructuralInvariants` | reply + forward + a message with a 3 000-char ASCII line in `textBody`, a 200-char subject with umlauts, 30 recipients, a 100 KB random attachment named `"Ängebot ß.pdf"` with mime `"Application/PDF"` | output contains no lone LF or CR (every `0x0A` preceded by `0x0D`, every `0x0D` followed by `0x0A`); every line ≤ 998 bytes; `"MIME-Version: 1.0"` occurs exactly once; every base64 line ≤ 76 chars; contains `filename="_ngebot _.pdf"; filename*=UTF-8''%C3%84ngebot%20%C3%9F.pdf` and `Content-Type: application/pdf; name="_ngebot _.pdf"`; every header line ≤ 78 chars except lines starting with `Content-Type:`, `Content-Disposition:` and `Subject:` |
| | `testHeaderOrderAndOptionalHeaders` | reply inputs with `cc: []`, `inReplyTo: nil`, `references: []` | header names in order `From, To, Subject, Date, Message-ID, MIME-Version, Content-Type`; no `Cc:`, `In-Reply-To:`, `References:` lines |
| | `testRandomBoundariesDiffer` | `.random` twice | two `build` outputs differ; each boundary matches `=_minimail_alt_` + 16 hex; `boundary(kind:"alt") != boundary(kind:"alt")` on successive calls |
| | `testDateStampedFromInput` | two builds with dates 1 s apart | `Date:` lines differ by one second |
| `ComposeStyleTests.swift` | `testDefaults` | `ComposeStyle()` | family `.helvetica`, 14, `"#000000"`, `inlineCSS == "font-family:Helvetica, Arial, sans-serif;font-size:14px;color:#000000"` |
| | `testClampAndHex` | `init(family: .courier, sizePx: 40, colorHex: "#ABCDEF")`; `sizePx = 3` mutated afterwards; `colorHex = "nope"` | 18 / `"#abcdef"`; `inlineCSS` contains `font-size:12px`; `inlineCSS` contains `color:#000000`; `isValidColorHex("#abcdef")`, `!isValidColorHex("#ABCDEF")`, `!isValidColorHex("#abcd")` |
| | `testFamilyCSS` | all cases | exact strings of §4.14; `displayName` values of §3.14 |
| | `testDecodeLenient` | JSON `{}`; `{"family":"comic","sizePx":40,"colorHex":"#ABCDEF"}`; `{"sizePx":"x"}` | default; `.helvetica`/18/`"#abcdef"`; default (type mismatch on a field → default for that field, no throw) |
| | `testEncodeSortedKeys` | default with `.sortedKeys` | `{"colorHex":"#000000","family":"helvetica","sizePx":14}` |
| `ReplyAllTests.swift` | `testVectors` | `vectors/reply-all.json`, `me` of §4.15 | `recipients(...).to == parseList(expectedTo)` and `.cc == parseList(expectedCc)` for all 16 rows; row 7 serialized check |
| | `testSelfIdentityNormalises` | `SelfIdentity(primary: Mailbox(name: nil, addr: "Max@NewTelco.de"), allAddresses: ["M.Mustermann@newtelco.de"])` | `allAddresses == ["max@newtelco.de", "m.mustermann@newtelco.de"]` |
| `SubjectPrefixTests.swift` | `testVectors` | `vectors/subject.json` | `reply(original) == reply`, `forward(original) == forward` for all rows; RFC 2047 assertions of §5.4 |
| | `testStripForDisplay` | `"Re: Fwd: AW: Angebot"`, `"Re[2]: x"`, `"Rewards: x"`, `"Re: "`, `"Fwd:Angebot"`, `"  WG: Re: Hallo  "`, `"Angebot"` | `"Angebot"`, `"x"`, `"Rewards: x"`, `""`, `"Angebot"`, `"Hallo"`, `"Angebot"` |
| `QuotingTests.swift` | `testAttributionLine` | author `Alice Müller <alice@example.com>`, date 1789024353, Europe/Berlin; author nil | `"On Thu, Sep 10, 2026 at 9:12\u{202F}AM Alice Müller <alice@example.com> wrote:"`; `"On Thu, Sep 10, 2026 at 9:12\u{202F}AM wrote:"` |
| | `testReplyHTMLSkeleton` | `QuoteSource(author: Alice, date: 1789024353, subject: "Angebot für die Erweiterung", to: [Max], cc: [Carol], html: "<div dir=\"ltr\">Hallo Max</div>", text: "Hallo Max")`, Europe/Berlin | result == the exact string `<div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On Thu, Sep 10, 2026 at 9:12\u{202F}AM Alice Müller &lt;<a href="mailto:alice@example.com">alice@example.com</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"><div dir="ltr">Hallo Max</div></blockquote></div>` |
| | `testReplyHTMLFallsBackToPlainText` | same with `html: nil`, `text: "a < b\n\nc"` | blockquote content == `PlainTextHTML.convert("a < b\n\nc")` |
| | `testReplyTextQuoting` | `text: "Hallo Max,\n\nist das Angebot?\n\nGruß\nAlice\n"` | `"On Thu, Sep 10, 2026 at 9:12\u{202F}AM Alice Müller <alice@example.com> wrote:\n> Hallo Max,\n>\n> ist das Angebot?\n>\n> Gruß\n> Alice"` |
| | `testForwardHTMLSkeleton` | same source as the reply test | result == the exact string `<div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>From: <strong class="gmail_sendername" dir="auto">Alice Müller</strong> <span dir="auto">&lt;<a href="mailto:alice@example.com">alice@example.com</a>&gt;</span><br>Date: Thu, Sep 10, 2026 at 9:12\u{202F}AM<br>Subject: Angebot für die Erweiterung<br>To: Max Mustermann &lt;<a href="mailto:max.mustermann@newtelco.de">max.mustermann@newtelco.de</a>&gt;<br>Cc: Carol Chen &lt;<a href="mailto:carol@partner.example">carol@partner.example</a>&gt;<br></div><br><br><div dir="ltr">Hallo Max</div></div>` |
| | `testForwardOmitsEmptyCcAndEscapes` | `cc: []`, subject `"a <b> & c"`, author name `"X \"Y\""` | no `Cc:` in HTML or text; HTML contains `Subject: a &lt;b&gt; &amp; c` and `X &quot;Y&quot;`; text contains `Subject: a <b> & c` |
| | `testForwardText` | source of the reply test with `text: "Hallo Max,\n\nGruß\nAlice"` | `"---------- Forwarded message ---------\nFrom: Alice Müller <alice@example.com>\nDate: Thu, Sep 10, 2026 at 9:12\u{202F}AM\nSubject: Angebot für die Erweiterung\nTo: Max Mustermann <max.mustermann@newtelco.de>\nCc: Carol Chen <carol@partner.example>\n\n\nHallo Max,\n\nGruß\nAlice"`; banner prefix has 10 hyphens and suffix 9 |
| | `testTextFromHTML` | the 4 examples of §4.17.6 plus `"<p>x&#252;y&#x41;&unknown;</p>"` | exact strings; last → `"xüyA&unknown;"` |
| `OutgoingBodiesTests.swift` | `testEscape` | `"a & <b> \"c\" 'd'"` | `"a &amp; &lt;b&gt; &quot;c&quot; 'd'"` |
| | `testWrapperAndLines` | `typed: "Hi <Bob>\n\nBye"`, default style | exact string of §4.18; `typed: ""` → `<div dir="ltr" class="minimail_default" style="…"><div><br></div></div>` |
| | `testSignatureBlock` | signature `"<b>Max</b>"`, style `.arial`/16/`"#112233"` | output contains `</div><div><br></div><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature"><div style="font-family:Arial, Helvetica, sans-serif;font-size:16px;color:#112233"><b>Max</b></div></div>`; signature `"   "` → no `gmail_signature` in output |
| | `testQuoteOutsideWrapper` | quote `"<div class=\"gmail_quote\">Q</div>"` | output ends with `</div><br><div class="gmail_quote">Q</div>`; the substring before `<br><div class="gmail_quote"` has balanced `<div`/`</div>` counts (the wrapper is closed before the quote) |
| | `testDocument` | `"<p>x</p>"` | `"<html><head><meta charset=\"utf-8\"></head><body><p>x</p></body></html>"`; does not contain `color-scheme` |
| | `testTextLayout` | the example of §4.18; no signature; no quote; both nil | exact; `"typed\n\nquote"`; `"typed\n\n-- \nsig"`; `"typed"`; typed with `"\r\n"` line breaks normalised |
| `PlainTextHTMLTests.swift` | `testExamples` | the 4 examples of §4.19 | exact strings |
| | `testLinkifyEdgeCases` | `"http://x"` → linked; `"https://"` → not linked; `"www."` → not linked; `"See <https://a.b>, ok"` → `See &lt;<a href="https://a.b">https://a.b</a>&gt;, ok`; `"HTTPS://X.Y"` → linked with `href="HTTPS://X.Y"` | as listed |

Fixture support test (in `Base64URLTests.swift` as `testFixturesPresent`): `Fixture.data("mime/stub.pdf").count == 125`, `Fixture.sha256Hex("mime/reply-all.sha256") == "b9f8078c1d50352b00f1486624bb2247ec19587ccf388b652aed62da0d1fcbd3"` — fails fast when the resource copy is broken.

App tests via `xcodebuild`: none in this module (the app test bundle only copies the fixtures, project.yml of module 01).

---

## 8. Tasks

Each task: files touched → definition of done → verification command. Run `cd /path/to/minimail && make lint` after every task (formatting + package-boundary grep). Order is dependency order.

- [ ] **T2.1 Base64URL, QuotedPrintable, fixture loader, first vectors**
  Files: `Sources/MailCore/Encoding/Base64URL.swift`, `Sources/MailCore/Encoding/QuotedPrintable.swift`, `Tests/MailCoreTests/Support/Fixtures.swift`, `Tests/MailCoreTests/Fixtures/vectors/base64.json`, `Tests/MailCoreTests/Fixtures/vectors/qp.json`, `Tests/MailCoreTests/Base64URLTests.swift` (without `testRawFixtureRoundTrip`/`testFixturesPresent`, added in T2.6), `Tests/MailCoreTests/QuotedPrintableTests.swift`.
  Done when: §4.1–§4.2 implemented byte-level; both test files green; `Bundle.module` resolves the vectors on Linux.
  Verify: `cd Packages/MailCore && swift test --filter 'Base64URLTests|QuotedPrintableTests'`

- [ ] **T2.2 Charsets and RFC 2047**
  Files: `Sources/MailCore/Encoding/Charsets.swift`, `Sources/MailCore/Encoding/RFC2047.swift`, `Tests/MailCoreTests/Fixtures/vectors/rfc2047.json`, `Tests/MailCoreTests/CharsetsTests.swift`, `Tests/MailCoreTests/RFC2047Tests.swift`.
  Done when: table of §5.3 complete; decode chain never returns nil; the 9 decode rows and the encode tests pass; exotic-charset tests are guarded as specified.
  Verify: `cd Packages/MailCore && swift test --filter 'CharsetsTests|RFC2047Tests'`

- [ ] **T2.3 ContentTypeParams and RFC 2231**
  Files: `Sources/MailCore/Headers/ContentTypeParams.swift`, `Sources/MailCore/Encoding/RFC2231.swift`, `Tests/MailCoreTests/Fixtures/vectors/rfc2231.json`, `Tests/MailCoreTests/ContentTypeParamsTests.swift`, `Tests/MailCoreTests/RFC2231Tests.swift`.
  Done when: hand-written `==` compiles under Swift 6 strict concurrency; all 6 filename rows and the encoder cases pass.
  Verify: `cd Packages/MailCore && swift test --filter 'ContentTypeParamsTests|RFC2231Tests'`

- [ ] **T2.4 Mailbox and AddressParser**
  Files: `Sources/MailCore/Headers/Mailbox.swift`, `Sources/MailCore/Headers/HeaderFolding.swift` (only `unfold` is needed here; `fold*` come in T2.5 — implement the whole file in this task to keep one file per task), `Sources/MailCore/Headers/AddressParser.swift`, `Tests/MailCoreTests/Fixtures/vectors/addresses.json`, `Tests/MailCoreTests/MailboxTests.swift`, `Tests/MailCoreTests/AddressParserTests.swift`, `Tests/MailCoreTests/HeaderFoldingTests.swift`.
  Done when: the 15 address rows, the garbage cases and the serializer forms pass; `parseList` never traps on any input of `testGarbageDoesNotCrash`.
  Verify: `cd Packages/MailCore && swift test --filter 'MailboxTests|AddressParserTests|HeaderFoldingTests'`

- [ ] **T2.5 HeaderDate and MessageIDs**
  Files: `Sources/MailCore/Headers/HeaderDate.swift`, `Sources/MailCore/Headers/MessageIDs.swift`, `Tests/MailCoreTests/HeaderDateTests.swift`, `Tests/MailCoreTests/MessageIDsTests.swift`.
  Done when: format/attribution strings match on Linux and macOS (`DateFormatter` + en_US_POSIX); the parse matrix and the references-chain cases pass.
  Verify: `cd Packages/MailCore && swift test --filter 'HeaderDateTests|MessageIDsTests'`

- [ ] **T2.6 OutgoingMessage, MIMEBuilder, byte-exact fixtures**
  Files: `Sources/MailCore/MIME/OutgoingMessage.swift`, `Sources/MailCore/MIME/MIMEBuilder.swift`, `Tests/MailCoreTests/Fixtures/mime/{reply-all.eml,reply-all.sha256,reply-all.raw.txt,forward-pdf.eml,forward-pdf.sha256,forward-pdf.raw.txt,forward-pdf-gmailweb.eml,forward-pdf-gmailweb.sha256,stub.pdf,.gitattributes}` (generated by the §5.1 script), `Tests/MailCoreTests/MIMEBuilderTests.swift`, plus `testRawFixtureRoundTrip` and `testFixturesPresent` in `Base64URLTests.swift`.
  Done when: `sha256sum -c` prints three `OK`; all three byte-exact tests pass on Linux; structural invariants pass; `git diff --stat` shows the `.eml` files as binary-safe (`.gitattributes` in place; `git ls-files --eol` reports `w/crlf` for them).
  Verify: `cd Packages/MailCore && swift test --filter 'MIMEBuilderTests|Base64URLTests' && cd Tests/MailCoreTests/Fixtures/mime && sha256sum -c *.sha256`

- [ ] **T2.7 ComposeStyle, SubjectPrefix, ReplyAll**
  Files: `Sources/MailCore/Compose/ComposeStyle.swift`, `Sources/MailCore/Compose/SubjectPrefix.swift`, `Sources/MailCore/Compose/ReplyAll.swift`, `Tests/MailCoreTests/Fixtures/vectors/{reply-all.json,subject.json}`, `Tests/MailCoreTests/ComposeStyleTests.swift`, `Tests/MailCoreTests/SubjectPrefixTests.swift`, `Tests/MailCoreTests/ReplyAllTests.swift`.
  Done when: all 16 reply-all rows pass through `AddressParser` → `ReplyAll` → comparison; subject rows and `stripForDisplay` cases pass; lenient Codable of `ComposeStyle` verified.
  Verify: `cd Packages/MailCore && swift test --filter 'ComposeStyleTests|SubjectPrefixTests|ReplyAllTests'`

- [ ] **T2.8 PlainTextHTML, Quoting, OutgoingBodies**
  Files: `Sources/MailCore/Compose/PlainTextHTML.swift`, `Sources/MailCore/Compose/Quoting.swift`, `Sources/MailCore/Compose/OutgoingBodies.swift`, `Tests/MailCoreTests/PlainTextHTMLTests.swift`, `Tests/MailCoreTests/QuotingTests.swift`, `Tests/MailCoreTests/OutgoingBodiesTests.swift`.
  Done when: the exact skeleton strings of §7 match; an end-to-end assembly (`OutgoingBodies.html` + `Quoting.replyHTML` → `OutgoingBodies.document` → `MIMEBuilder.build`) produces a message whose decoded HTML part contains `gmail_quote_container`, `minimail_default` and no `color-scheme` (add this as `testEndToEndAssembly` in `OutgoingBodiesTests.swift`: build with `.fixed` boundaries, split the output on the alt boundary, `QuotedPrintable.decode` the html part, assert the three substrings).
  Verify: `cd Packages/MailCore && swift test --filter 'PlainTextHTMLTests|QuotingTests|OutgoingBodiesTests'`

- [ ] **T2.9 Whole-module pass**
  Files: none new; formatting fixes only.
  Done when: `make core-test` is green on Linux; `make lint` passes (`swift format lint --strict`, the `import` greps); `grep -rnE "Regex|NSRegularExpression|try!|as!" Packages/MailCore/Sources/MailCore` prints nothing; test count for this module ≥ 60 functions; total `swift test` wall time for the module < 30 s on the Linux CI runner.
  Verify: `make core-test && make lint && cd Packages/MailCore && swift test 2>&1 | grep -E "Executed [0-9]+ tests"`

---

## 9. Acceptance criteria

1. `cd Packages/MailCore && swift test` passes on Linux (Swift 6.1 toolchain) and on macOS (Xcode 26.6) with zero failures and zero skipped tests other than the documented `skip-if-unsupported` charset case on Linux. Command: `make core-test`.
2. `MIMEBuilder.build` reproduces `Fixtures/mime/reply-all.eml` (2276 bytes, sha256 `b9f8078c1d50352b00f1486624bb2247ec19587ccf388b652aed62da0d1fcbd3`), `forward-pdf.eml` (2927 bytes, `2127dc5426a76d3deb405f04f30b602d22461af3b8ea6dbdee8d494d66429261`) and `forward-pdf-gmailweb.eml` (2971 bytes, `d8dc2b8522a8354d8cb0709757660d1ddea87f342d75a23752bb619cf9e74d86`) byte for byte. Command: `swift test --filter MIMEBuilderTests`.
3. `Base64URL.encode(fixture) == fixture.raw.txt + "="` for both raw fixtures (padded output, `[mime-rfc §1.2]` decision). Command: `swift test --filter Base64URLTests/testRawFixtureRoundTrip`.
4. All 16 reply-all rows of `[mime-rfc §8.1]`, 7 subject rows of `§8.2`, 7 QP rows, 9 RFC 2047 rows, 6 base64 rows, 6 RFC 2231 rows and 15 address rows pass from the JSON vector files (no expected value is typed twice). Command: `swift test --filter 'ReplyAllTests|SubjectPrefixTests|QuotedPrintableTests|RFC2047Tests|Base64URLTests|RFC2231Tests|AddressParserTests'`.
5. `make lint` passes: `swift format lint --strict` clean; `grep -rE "^import (UIKit|SwiftUI|GRDB|AppAuth|WebKit|Security|CoreFoundation)" Packages/MailCore/Sources` and `grep -rE "^import SwiftSoup" Packages/MailCore/Sources/MailCore` find nothing; additionally `grep -rnE "Regex|NSRegularExpression" Packages/MailCore/Sources/MailCore` finds nothing.
6. Every public symbol listed in §3 exists with the exact signature (a consumer file compiled in module 03/07/11 that references each symbol builds without edits). Manual check: `grep -n "public static func\|public struct\|public enum\|public var\|public init" Packages/MailCore/Sources/MailCore/{Encoding,Headers,MIME,Compose}/*.swift` matches the list in §3.
7. No function in the module throws or traps on adversarial input: `testGarbageDoesNotCrash`, `testDecodeRejectsGarbage`, `testDecodeTolerant`, `testDecodeLenient` pass.
8. Attribution and forward banners carry the exact Gmail markers: U+202F before AM/PM, classes `gmail_quote_container`, `gmail_attr`, `gmail_quote`, `gmail_sendername`, `gmail_signature_prefix`, `gmail_signature`, banner `---------- Forwarded message ---------` (10/9 hyphens). Command: `swift test --filter 'QuotingTests|OutgoingBodiesTests'`.
9. `OutgoingBodies.document` output never contains the substring `color-scheme`; `OutgoingBodies.html` places the quote after the closing `</div>` of the `minimail_default` wrapper. Command: `swift test --filter OutgoingBodiesTests`.
10. Fixture bytes survive git: `git ls-files --eol Packages/MailCore/Tests/MailCoreTests/Fixtures/mime/*.eml` reports `i/crlf w/crlf attr/-text` for each `.eml`; a fresh clone re-passes criterion 2.

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption chosen |
|---|---|---|---|
| 1 | Foundation `Data(base64Encoded:)` rejects unpadded input and the `-`/`_` alphabet (`[mime-rfc §1.2, §10 item 5]`) | UNVERIFIED (Apple docs blocked) | `Base64URL.decode` always re-pads and swaps the alphabet before calling Foundation; the vectors of §5.4 prove the behaviour on both platforms. |
| 2 | `String(data:encoding:)` support on Linux for `.windowsCP1252`, `.shiftJIS`, `.japaneseEUC`, `.iso2022JP`, `.isoLatin2` and the `0x8000_xxxx` raw-value encodings; the raw values themselves (`[mime-rfc §10 item 5]`) | UNVERIFIED | Table kept; `Charsets.decode` falls through to UTF-8 then Latin-1 so no caller can fail; exotic tests are Darwin-only or skip when unsupported. If a raw value proves wrong on macOS, fix the constant — no design change. |
| 3 | Whether Gmail accepts unpadded base64url in `raw` (`[mime-rfc §10 item 2]`) | UNVERIFIED | Irrelevant: we emit padded output, which Google's own sample does. |
| 4 | Whether Gmail's "Subject headers must match" threading rule ignores `Re:`/`Fwd:` (`[mime-rfc §10 item 1]`) | UNVERIFIED | Prefixes are added exactly as Gmail web does (`SubjectPrefix`); the text after the prefix is kept byte-identical. |
| 5 | Gmail web's position of the `Cc:` line in the forward banner (`[mime-rfc §10 item 7]`) | UNVERIFIED | After `To:`, as Google's CLI does and as the byte-exact §7.2 fixture shows. |
| 6 | Forward threading headers: the research's byte-exact §7.2 omits `In-Reply-To`; the architecture (D24, §7.2) sends `threadId` + `In-Reply-To` + `References` on forwards (Gmail-web behaviour) | decided by architecture | `MIMEBuilder` emits `In-Reply-To` whenever `OutgoingMessage.inReplyTo` is non-nil; module 11 sets it for forwards. Both fixtures are pinned; production uses the Gmail-web variant. |
| 7 | RFC 3676 citation for the `-- ` signature separator (`[mime-rfc §10 item 6]`) | UNVERIFIED citation | The convention is implemented regardless (`OutgoingBodies.text`, QP `--=20`). |
| 8 | `PlainTextHTML.convert` output carries class `mm-plaintext` but no inline `white-space:pre-wrap`; inside outgoing quotes (reply to a text-only mail) runs of spaces therefore collapse in the recipient's client | assumption | Follows architecture §7.3 literally (`PlainTextHTML.convert(text)`); the thread-view CSS of module 08 styles `.mm-plaintext`. Stage-2 option: an inline style on the wrapper. |
| 9 | ASCII fallback filename for non-ASCII attachment names (`Ängebot.pdf` → `_ngebot.pdf`) | assumption | Underscore substitution, deterministic and Linux-safe (no `folding(options:)` reliance); modern clients read `filename*`. |
| 10 | `Subject` lines longer than 78 characters are not folded when ASCII (only the 998 MUST is guaranteed via forced encoding above 900 characters); the fixture's `Content-Type:` line is 79 characters | assumption | Accepted; identical to the pinned research fixtures, within RFC 5322 §2.1.1 MUST. |
| 11 | `ContentTypeValue: Equatable` cannot be synthesised for `[(String, String)]` | fact | Hand-written `==` (DEVIATION note in §3.10); call sites unchanged. |
| 12 | Extra public initialisers and helpers (`ContentTypeValue.init`, `OutgoingAttachment.init`, `OutgoingMessage.init`, `SelfIdentity.init`, `Recipients.init`, `QuoteSource.init`, `ComposeStyle.init(family:sizePx:colorHex:)`, `ComposeStyle.isValidColorHex`, `normalizedColorHex`, `minSizePx`, `maxSizePx`, `defaultColorHex`) | ADDITION | Required for cross-module construction of public structs (Swift synthesises only internal memberwise inits); none changes an architecture call site. |
| 13 | `QuoteSource.date` JSON representation depends on the caller's `JSONEncoder.dateEncodingStrategy` | assumption | Modules 07 and 11 use the same default strategy (`.deferredToDate`); documented in §5.5. |
| 14 | `SubjectPrefix.reply/forward` trim surrounding whitespace before prefixing | assumption | Harmless normalisation; header values are trimmed on parse anyway; `[mime-rfc §8.2]` rows unaffected. |
| 15 | `HeaderDate.parse` maps unknown alphabetic zones to +0000 and single-letter military zones to +0000 | assumption | RFC 5322 §4.3 says unknown zones "SHOULD be considered equivalent to -0000"; `Date` header is never stored (architecture §3.3), so precision is irrelevant. |
| 16 | `swift:6.1` Docker tag / Linux toolchain availability for `swift test` (`[tooling §7.4]`) | UNVERIFIED (module 01) | The macOS CI job also runs `make core-test`, so this module's tests always run at least once per CI run. |
| 17 | `AddressParser` treats an unquoted top-level `:` as the start of an RFC 5322 group (`Re: foo <a@b>` would lose the display name `Re`) | assumption | Same behaviour as Python's `email.utils.getaddresses` (the research oracle, `[mime-rfc §8.4]`); display names with an unquoted colon are quoted by every conformant sender. |
