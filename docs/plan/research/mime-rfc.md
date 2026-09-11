# MIME / RFC 5322 construction and parsing for minimail (no third-party MIME library)

Date: 2026-09-11. Scope: everything the Swift `Gmail/` module needs to (1) build RFC 5322 messages for `users.messages.send`, (2) compute reply-all recipients, (3) build multipart HTML mail with the HTML signature, (4) quote/forward in Gmail's conventions, (5) parse Gmail `format=full` payloads, (6) re-attach original attachments on forward.

## 0. Verification status (read first)

Network egress in this session blocked `developers.google.com`, `support.google.com`, `rfc-editor.org`, `ietf.org`, `datatracker.ietf.org`, `tools.ietf.org`, `docs.python.org`, `developer.apple.com`, Wikipedia and every RFC mirror site. What **was** reachable and is the basis for every claim below:

| Tag | Source | Status |
|---|---|---|
| **[DISC]** | Gmail API Discovery document, `https://gmail.googleapis.com/$discovery/rest?version=v1`, `"revision": "20260907"` (official, machine-readable; the REST reference pages are generated from it) | verified, quoted verbatim |
| **[RFC]** | Full text of RFC 5322, 2045, 2046, 2047, 2049, 2183, 2231, 2387, 6532 (from `github.com/jstedfast/MimeKit/rfc/`), RFC 4648 (`github.com/django-oauth/django-oauth-toolkit/rfcs/`), RFC 2392 (`github.com/aaspring/rfcRepository`) — byte-identical copies of the IETF text | verified, quoted with section numbers; canonical URLs are `https://www.rfc-editor.org/rfc/rfcNNNN.txt` |
| **[GWS-CLI]** | Google's own `googleworkspace/cli` (Rust), files `crates/google-workspace-cli/src/helpers/gmail/{reply.rs,forward.rs,mod.rs}` on `main` — Google-authored reply-all / forward / attachment logic against this same API | verified (raw.githubusercontent.com) |
| **[GWS-SAMPLE]** | `googleworkspace/python-samples/gmail/snippet/send mail/send_message.py` (the code behind the official "Create and send email messages" guide) | verified |
| **[FIXTURE]** | Real Gmail-web-generated messages: a reply (`sajjadium/ctf-archives`, 2025, `gmail_quote_container` markup), a forward (`rf-peixoto/phishing_pot email/sample-315.eml`, 2023), an inline-image draft (`GAM-team/got-your-back samples/gyb-format/.../16a281480109495b.eml`, 2019), `mailgun/talon` reply fixtures (2012/2014) | verified — these show what Gmail itself emits |
| **[SNIPPET]** | Web-search result snippets quoting a page I could not open | likely correct, not byte-verified |
| **UNVERIFIED** | could not confirm from any of the above | treat as a hypothesis; test on the real account |

Official page URLs to cite in the plan (blocked here): sending guide `https://developers.google.com/workspace/gmail/api/guides/sending`, threads guide `https://developers.google.com/workspace/gmail/api/guides/threads`, `users.messages.send` reference `https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send`, `users.messages.attachments.get` `https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get`.

---

## 1. Building outgoing messages for `users.messages.send`

### 1.1 Transport contract **[DISC]**

- `POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send`, JSON body = `Message` with:
  - `raw` (string, `format: byte`): "The entire email message in an RFC 2822 formatted and base64url encoded string."
  - `threadId` (string, optional): see 1.4.
- Method description: "Sends the specified message to the recipients in the `To`, `Cc`, and `Bcc` headers." ⇒ the **RFC 5322 headers are the envelope**; there is no separate recipient field.
- Scopes include `https://www.googleapis.com/auth/gmail.modify` ⇒ no extra scope needed.
- Media-upload alternative: `POST https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=media` (`mediaUpload.simple.path = "/upload/gmail/v1/users/{userId}/messages/send"`, `accept: ["message/*"]`, `maxSize: "36700160"` = 35 MiB). Body = the **unencoded** RFC 5322 bytes with `Content-Type: message/rfc822`; `threadId` then goes in the multipart-upload metadata part as `{"threadId": "..."}` **[GWS-CLI mod.rs `build_send_metadata`]**. Use this path for forwards with large attachments (no 33 % base64 inflation, no JSON string limits). For stage 1 the JSON path is fine.
- Response: a `Message` (in practice `{"id","threadId","labelIds":["SENT"]}`; exact minimal shape UNVERIFIED).

### 1.2 `raw` encoding — base64url, padding **[DISC + RFC 4648 + GWS-SAMPLE]**

- Alphabet: RFC 4648 §5 "URL and Filename safe" — identical to base64 except value 62 = `-` and 63 = `_`. **[RFC 4648 §5, Table 2]**
- Line feeds: RFC 4648 §3.1 "Implementations MUST NOT add line feeds to base-encoded data unless the specification referring to this document explicitly directs" ⇒ **one line, no CRLF** inside `raw`.
- Padding: RFC 4648 §3.2 "Implementations MUST include appropriate pad characters at the end of encoded data unless the specification referring to this document explicitly states otherwise"; §5: "The pad character "=" is typically percent-encoded when used in an URI, but if the data length is known implicitly, this can be avoided by skipping the padding". Google's official sample **keeps the padding**: `encoded_message = base64.urlsafe_b64encode(message.as_bytes()).decode()` (Python's `urlsafe_b64encode` pads) **[GWS-SAMPLE]**. Gmail's own *responses* (`payload.body.data`, `attachments.get.data`, `raw`) are usually **unpadded** **[SNIPPET: javaspring.net, gmail-api.md §"Common facts"]**. Unpadded input is also accepted in practice **[SNIPPET; UNVERIFIED as documented text]**.
- **Decision for minimail**: **emit padded base64url** (matches Google's sample and RFC 4648 §3.2), **accept both** when decoding. Swift:
  ```swift
  // encode (padded): Foundation base64 + alphabet swap
  let raw = data.base64EncodedString()               // no line breaks by default
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  // decode (tolerant): swap back, then pad to a multiple of 4
  func base64urlDecode(_ s: String) -> Data? {
      var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      let rem = t.count % 4
      if rem != 0 { t += String(repeating: "=", count: 4 - rem) }
      return Data(base64Encoded: t)   // Foundation requires canonical padding — UNVERIFIED against Apple docs in this session (blocked); covered by the unit-test vectors in §8.3
  }
  ```
- Standard base64 (`+`, `/`) in `raw` is rejected with HTTP 400 "Invalid value … Base64 decoding failed" **[SNIPPET: github dart-lang/googleapis#109, cli.nylas.com]**.

### 1.3 Required and recommended headers **[RFC 5322 §3.6]**

RFC 5322 §3.6 table (min/max per message): `orig-date` **1/1**, `from` **1/1**, `sender` 0/1 ("MUST occur with multi-address from"), `reply-to` 0/1, `to` 0/1, `cc` 0/1, `bcc` 0/1, `message-id` 0/1 "SHOULD be present", `in-reply-to` 0/1 and `references` 0/1 "SHOULD occur in some replies", `subject` 0/1. "The only required header fields are the origination date field and the originator address field(s)."

Emit exactly these, in this order (order is not semantically significant, RFC 5322 §3.6, but fixed order makes byte-exact tests possible):

| Header | Value rule | Source |
|---|---|---|
| `From:` | `display-name <addr-spec>`; display name from `sendAs.displayName`/`getProfile` (RFC 2047-encode if non-ASCII; quote if it contains specials). Gmail rewrites `From` to the account's address if it does not match a verified send-as **[SNIPPET, UNVERIFIED]** | RFC 5322 §3.6.2, §3.4 |
| `To:` / `Cc:` | `address-list`, comma-separated `mailbox`es; omit the header if empty (`bcc` may be empty, `to`/`cc` should not be sent empty) | §3.6.3 |
| `Subject:` | unstructured; non-ASCII ⇒ RFC 2047 encoded-words (§2.4) | §3.6.5 |
| `Date:` | `date-time` = `[ day-of-week "," ] day month year hour ":" minute [ ":" second ] zone`, e.g. `Fri, 11 Sep 2026 10:00:00 +0200`; "The date and time-of-day SHOULD express local time"; zone `+hhmm`/`-hhmm`; day-of-week MUST match the date | §3.3 |
| `Message-ID:` | `"<" id-left "@" id-right ">"`; `id-left = dot-atom-text` (no CFWS, no quoted-string); RECOMMENDED that id-right is a domain the generator controls; MUST be globally unique. Use `<UUID@newtelco.de>` (uppercase UUID is fine: `atext` includes A–Z, 0–9, `-`). **Always set it** — you need it locally for the outbox `rfc822msgid:` idempotency check (gmail-api.md §14) | §3.6.4 |
| `In-Reply-To:` / `References:` | replies only, see 1.4 | §3.6.4 |
| `MIME-Version: 1.0` | "Messages composed in accordance with this document MUST include such a header field, with the following verbatim text: `MIME-Version: 1.0`"; required at the top level only, not per body part | RFC 2045 §4 |
| `Content-Type:` | `multipart/alternative; boundary="..."` or `multipart/mixed; boundary="..."` (§3) | RFC 2046 §5.1.1 |

Line format: every line ends with **CRLF**; "Each line of characters MUST be no more than 998 characters, and SHOULD be no more than 78 characters, excluding the CRLF" **[RFC 5322 §2.1.1]** (RFC 6532 §3.4: the 998 is **octets**). Headers must be pure US-ASCII ("in no event are headers … allowed to contain anything other than US-ASCII characters" **[RFC 2046 §5.1.1 NOTE]**) unless the whole message is an SMTPUTF8 `message/global` (RFC 6532) — **do not** rely on that; use RFC 2047. Fold long header lines at FWS positions (`CRLF` + `SPACE`) — RFC 5322 §2.2.3; simplest: fold `To:`/`Cc:`/`References:` after each comma / msg-id when a line would exceed 78.

### 1.4 Threading headers (reply) **[RFC 5322 §3.6.4 + DISC]**

RFC 5322 §3.6.4, verbatim construction rules:

> The "In-Reply-To:" field will contain the contents of the "Message-ID:" field of the message to which this one is a reply (the "parent message"). … If there is no "Message-ID:" field in any of the parent messages, then the new message will have no "In-Reply-To:" field.
>
> The "References:" field will contain the contents of the parent's "References:" field (if any) followed by the contents of the parent's "Message-ID:" field (if any). If the parent message does not contain a "References:" field but does have an "In-Reply-To:" field containing a single message identifier, then the "References:" field will contain the contents of the parent's "In-Reply-To:" field followed by the contents of the parent's "Message-ID:" field (if any). If the parent has none of the "References:", "In-Reply-To:", or "Message-ID:" fields, then the new message will have no "References:" field.

Algorithm (exactly what Google's CLI does, `build_references_chain`: `refs = original.references; if message_id non-empty { refs.push(message_id) }` **[GWS-CLI mod.rs]**):

```
inReplyTo  = parent.messageID                                   // "<...>" incl. brackets, verbatim
references = (parent.references ?? (parent.inReplyTo.count == 1 ? parent.inReplyTo : [])) + [parent.messageID]
             // dedupe while preserving order; omit header if empty
```
Format: `References: <id1> <id2> <id3>` — msg-ids separated by a single space (CFWS is optional between msg-ids: `references = "References:" 1*msg-id CRLF`, `msg-id = [CFWS] "<" id-left "@" id-right ">" [CFWS]`). Keep the original angle-bracketed strings untouched (do not re-case, do not trim `=`/`+` — Gmail ids look like `<CAF=abc+123@mail.gmail.com>`).

Gmail's server-side threading criteria, `Message.threadId` **[DISC]** verbatim: "To add a message or draft to a thread, the following criteria must be met: 1. The requested `threadId` must be specified on the `Message` or `Draft.Message` you supply with your request. 2. The `References` and `In-Reply-To` headers must be set in compliance with the RFC 2822 standard. 3. The `Subject` headers must match." ⇒ JSON body for a reply is `{"threadId": "<original.threadId>", "raw": "..."}`. Note `threadId` only affects the sender's own mailbox grouping; recipients thread purely on `In-Reply-To`/`References` **[SNIPPET: cli.nylas.com]**.

**Subject rules for replies** **[RFC 5322 §3.6.5]**: "When used in a reply, the field body MAY start with the string "Re: " … followed by the contents of the "Subject:" field body of the original message. If this is done, only one instance of the literal string "Re: " ought to be used". Algorithm (Google CLI `build_reply_subject`, case-insensitive) **[GWS-CLI reply.rs]**:
```
if subject.lowercased().hasPrefix("re:") { subject } else { "Re: " + subject }
```
Google keeps an existing `RE:`/`re:` prefix untouched (test `build_reply_subject("RE: Hello") == "RE: Hello"`). Whether Gmail's "Subject headers must match" ignores `Re:`/`Fwd:` prefixes is **[SNIPPET: learn.emailengine.app, UNVERIFIED in official text]** — empirically yes (Gmail web itself sends `Re: `/`Fwd: ` subjects with `threadId`, see fixtures). Keep the text after the prefix byte-identical to the original subject (after RFC 2047 decoding; re-encode on output).

### 1.5 Forward: Subject, and the `In-Reply-To` question

- Subject: `if subject.lowercased().hasPrefix("fwd:") { subject } else { "Fwd: " + subject }` **[GWS-CLI forward.rs `build_forward_subject`; Gmail web uses `Fwd: ` — FIXTURE sample-315 `Subject: Fwd: It's Your Lucky Day!`]**. Do not normalise `FW:`/`WG:` (Outlook/German) — treat only `fwd:` as already-prefixed; stacking `Fwd: FW: x` is what Gmail does too (UNVERIFIED for Gmail web; harmless).
- **Whether a forward carries `In-Reply-To`/`References`**: the task premise ("forwards should NOT carry In-Reply-To") is **contradicted by Gmail's own behaviour**:
  - RFC 5322 §3.6.4 only defines the fields for replies and is silent on forwards; §3.6.6 explicitly says a forwarded message "is an entirely new message from the forwarder".
  - **Gmail web sets both** on a forward **[FIXTURE sample-315.eml]**: `References: <63ea6055…SMTPIN_ADDED_MISSING@mx.google.com>` and `In-Reply-To: <63ea6055…SMTPIN_ADDED_MISSING@mx.google.com>` together with `Subject: Fwd: …` (the id is the Gmail-synthesised Message-ID of the original, which lacked one).
  - Google's CLI forward also sets `in_reply_to: &original.message_id` and the full references chain, and passes `threadId` **[GWS-CLI forward.rs, test `test_create_forward_raw_message_without_body` asserts `In-Reply-To` present]**.
  - Gmail's threading criteria **[DISC]** require the `References`/`In-Reply-To` headers to keep the forward in the same thread in the owner's mailbox (PLAN.md wants `threadId`).
  - **Recommendation**: mirror Gmail web — set `threadId`, `References` (chain + original id) **and** `In-Reply-To` (original id) on forwards. This keeps the forward in the conversation in minimail/Gmail. Recipients' clients (Apple Mail, Outlook) may thread it under the original if they also received the original; that is exactly what happens with Gmail-web forwards today. If the owner insists on "forward = fresh conversation", omit **all three** (`threadId`, `In-Reply-To`, `References`) consistently — setting `threadId` without the headers does nothing **[DISC]**. The byte-exact forward example in §7.2 follows the RFC-purist variant the owner asked for (`References` kept for the chain, **no `In-Reply-To`**), and §7.3 says what to change for the Gmail-web variant.

---

## 2. Reply-all recipient computation and header parsing

### 2.1 Reply-all algorithm

RFC 5322 §3.6.2: "When the "Reply-To:" field is present, it indicates the address(es) to which the author of the message suggests that replies be sent. In the absence of the "Reply-To:" field, replies SHOULD by default be sent to the mailbox(es) specified in the "From:" field". §3.6.3: "the mailboxes of the authors of the original message (the mailboxes in the "From:" field) or mailboxes specified in the "Reply-To:" field (if it exists) MAY appear in the "To:" field of the reply … addresses in the "To:" and "Cc:" fields of the original message MAY appear in the "Cc:" field of the reply … If a "Bcc:" field is present in the original message, addresses in that field MAY appear in the "Bcc:" field of the reply, but they SHOULD NOT appear in the "To:" or "Cc:" fields."

The task specifies **To = Reply-To/From + original To; Cc = original Cc** (Gmail-web style). Google's CLI implements the RFC variant (To = Reply-To/From, Cc = original To + Cc) **[GWS-CLI reply.rs `build_reply_all_recipients`]**; both are RFC-conformant. Use the task's variant, plus Google's **self-reply rule** and exclusion logic, which are worth copying verbatim in spirit:

```
inputs:  from, replyTo?, to[], cc[]  (parsed mailboxes, RFC 2047-decoded display names)
         selfAddresses = { getProfile.emailAddress } ∪ { sendAs[*].sendAsEmail }   // all lowercased
                          // sendAs.list is readable with gmail.modify [DISC]; treatAsAlias irrelevant here
isSelfReply = selfAddresses.contains(from.addr.lowercased())

if isSelfReply:                           // replying to my own sent mail (Gmail ignores Reply-To here) [GWS-CLI]
    toCandidates = original.to
    ccCandidates = original.cc
else:
    toCandidates = (replyTo.isEmpty ? [from] : replyTo) + original.to
    ccCandidates = original.cc

seen = {}                                  // lowercased addr-spec
To = toCandidates.filter { m in
        let k = m.addr.lowercased()
        return !k.isEmpty && !selfAddresses.contains(k) && seen.insert(k) }
Cc = ccCandidates.filter { m in
        let k = m.addr.lowercased()
        return !k.isEmpty && !selfAddresses.contains(k) && seen.insert(k) }   // To wins over Cc [GWS-CLI dedup_recipients: "Priority: To > CC > BCC"]
if To.isEmpty && !Cc.isEmpty { To = Cc; Cc = [] }        // never send with empty To (Google's CLI errors instead)
if To.isEmpty { To = [from] }                             // last resort: reply to the author even if it is me
```
Rules embedded above: honour `Reply-To` over `From` (never both); case-insensitive comparison on the **addr-spec only** (display names ignored); dedupe across To then Cc; drop every self address (primary + every send-as alias); keep first-seen display name; original `Bcc` never present in received mail. Comparison is ASCII case-folding of the whole addr-spec — RFC 5321 says local-parts are case-sensitive in theory, but Gmail/Workspace local-parts are case-insensitive and Google's CLI lowercases the whole address (`email_lowercase`) — do the same.

### 2.2 Parsing `From`/`To`/`Cc`/`Reply-To` (RFC 5322 §3.4)

ABNF **[RFC 5322 §3.4, §3.4.1, §3.2.2, §3.2.4]**:
```
address-list = (address *("," address)) / obs-addr-list
address      = mailbox / group
mailbox      = name-addr / addr-spec
name-addr    = [display-name] angle-addr
angle-addr   = [CFWS] "<" addr-spec ">" [CFWS] / obs-angle-addr
group        = display-name ":" [group-list] ";" [CFWS]
display-name = phrase                     ; phrase = 1*word / obs-phrase ; word = atom / quoted-string
addr-spec    = local-part "@" domain
local-part   = dot-atom / quoted-string / obs-local-part
quoted-string= [CFWS] DQUOTE *([FWS] qcontent) [FWS] DQUOTE [CFWS]   ; qcontent = qtext / quoted-pair
comment      = "(" *([FWS] ccontent) [FWS] ")"                        ; ccontent = ctext / quoted-pair / comment  (nests)
CFWS         = (1*([FWS] comment) [FWS]) / FWS
```
Parser rules that matter (tokenizer, not regex):
1. Unfold first: remove every `CRLF` that is followed by WSP (RFC 5322 §2.2.3/§3.2.2: "any CRLF that appears in FWS is semantically 'invisible'").
2. Scan characters with state `{inQuote, commentDepth, inAngle}`; a `,` splits addresses only at depth 0 / outside quotes / outside `<…>`. Semicolon `;` at depth 0 ends a group. RFC 2047 encoded-words never contain `,` or `"` unencoded (RFC 2047 §2, §5(3)), so they do not disturb splitting.
3. `quoted-pair` (`\` + char) inside quotes and comments is the escaped char; quotes and parentheses are not part of the value (§3.2.4, §3.2.2).
4. Comments are dropped, **except** the legacy form `addr-spec (Name)` where the comment SHOULD be shown as display name (§3.4 Note: "Some legacy implementations … included the name of the recipient in parentheses as a comment following the addr-spec") — Python's stdlib does this too (§8.4 vectors).
5. Group syntax: flatten to its member mailboxes; an empty group (`Undisclosed recipients:;`) yields nothing.
6. `obs-route` (`<@a,@b:user@dom>`) — "the route portion SHOULD be ignored" (§4.4): strip everything up to the last `:` inside the angle brackets.
7. Display name: after collecting the phrase, apply RFC 2047 decoding to each encoded-word atom (§2.4); then strip one pair of surrounding DQUOTEs and unescape.
8. Output struct: `Mailbox(name: String?, addr: String)`; `addr` kept in original case for the header, `addr.lowercased()` for comparisons.

Google's CLI takes a shortcut (`rfind('<')` … `find('>')`, quotes-aware comma split, strip one pair of quotes) **[GWS-CLI mod.rs `Mailbox::parse`, `split_raw_mailbox_list`]** — acceptable for Gmail-normalised headers, but implement the tokenizer above; it is ~120 lines and the test vectors in §8.4 cover the corner cases.

**Serialising a mailbox for output**: `display-name` must be a `phrase`; if the (ASCII) name contains any of `()<>[]:;@\,."` or is not purely `atext`+spaces, emit it as a `quoted-string` with `"` and `\` escaped; if it contains non-ASCII, emit an RFC 2047 encoded-word instead (never quote an encoded-word: RFC 2047 §5 "An 'encoded-word' MUST NOT appear within a 'quoted-string'"). Always use `name <addr>` form (§3.4: "implementations SHOULD use the full name-addr form"). Never put an encoded-word inside `addr-spec`.

### 2.3 RFC 2047 encoded-words (names, Subject) **[RFC 2047 §2, §4, §5, §6.2]**

```
encoded-word = "=?" charset "?" encoding "?" encoded-text "?="
charset/encoding are case-insensitive; encoding ∈ {"B","Q"}; max 75 chars per encoded-word incl. delimiters;
each header LINE containing encoded-words ≤ 76 chars; no whitespace inside an encoded-word.
```
- **B** = RFC 2045 base64 (with `=` padding — each encoded-word must be self-contained, so B text length is a multiple of 4, §5).
- **Q**: `=XX` uppercase hex for any octet; `_` means 0x20 (always, regardless of charset); printable ASCII other than `=`, `?`, `_` may appear literally; SPACE/TAB MUST NOT appear literally. In a `phrase` (display names) the literal set is further restricted to `A–Z a–z 0–9 ! * + - / = _` (§5(3)) — so when **encoding** a display name with Q, escape everything else; simpler: **always encode with B** on output (allowed: "a mail reader … MUST be able to accept either encoding", §4).
- Where they may appear (§5): (1) in `*text` fields (Subject) separated from adjacent text by linear-white-space; (2) inside comments; (3) as a `word` in a `phrase` (display-name). NOT in addr-spec, NOT in quoted-string, NOT in Content-Type/Content-Disposition parameters (use RFC 2231 there, §2.4).
- Decoding rules: decode **after** tokenizing the structured field (§6.2 NOTE). "When displaying a particular header field that contains multiple 'encoded-word's, any 'linear-white-space' that separates a pair of adjacent 'encoded-word's is ignored" (§6.2) — i.e. `=?UTF-8?Q?a?= =?UTF-8?Q?b?=` → `ab`, but `plain =?UTF-8?B?w6Q=?= end` → `plain ä end` (whitespace between text and an encoded-word is kept). Each encoded-word "MUST represent an integral number of characters" (§5) — but real mail (Outlook) splits UTF-8 sequences across B words; be tolerant: concatenate the decoded **bytes** of adjacent same-charset encoded-words before UTF-8 decoding.
- Charsets to support: `UTF-8`, `US-ASCII`, `ISO-8859-1/-15`, `windows-1252`, `ISO-2022-JP`/`GB2312`/`Big5`/`KOI8-R` etc. via `CFStringConvertIANACharSetNameToEncoding` + `String(data:encoding:)`; on unknown charset or decode failure show the raw encoded-word (§6.2: "display the 'encoded-word' as ordinary text"). RFC 2231 §5 adds an optional `*lang` suffix to the charset (`=?UTF-8*de?B?...?=`) — strip `*…` before charset lookup.
- Encoding on output (Subject, display names): if the string is pure ASCII emit it as-is; otherwise split into UTF-8 chunks whose B-encoded form keeps each encoded-word ≤ 75 chars (`=?UTF-8?B?` + 4·ceil(n/3) + `?=` ⇒ n ≤ 45 bytes per word; never split inside a UTF-8 sequence), join words with `CRLF SPACE` (folding) — or with a single SPACE if the line stays ≤ 76 chars.

### 2.4 RFC 2231 parameter values (attachment filenames) **[RFC 2231 §3, §4, §4.1, §7]**

Parsing `Content-Disposition`/`Content-Type` parameters:
- Continuations: `filename*0=...; filename*1=...` — "The original parameter value is recovered by concatenating the various sections of the parameter, in order"; counts start at 0, decimal, no gaps; quoted and unquoted sections may be mixed.
- Charset/language: a trailing `*` on the name marks an **extended** value: `filename*=utf-8''%C3%84ngebot.pdf` = `charset ' language ' percent-encoded-octets`; "the single quote delimiters MUST be present even when one of the field values is omitted". Combined form: `filename*0*=utf-8''%C3%84nge; filename*1*=bot.pdf; filename*2="plain.pdf"` — only the first segment carries charset/language (§4.1 (1)); segments with `*` are percent-decoded, segments without are literal.
- Precedence when both `filename=` and `filename*=` exist: prefer `filename*` (RFC 6266 §4.3 for HTTP; for mail it is the conventional choice — UNVERIFIED as RFC 2231 text, which only says both may be present).
- Also decode RFC 2047 encoded-words if they appear in `filename="=?UTF-8?B?...?="` (illegal per RFC 2047 §5 but common in the wild; Gmail's `MessagePart.filename` is already decoded for you — see §5).
- Output (our attachments on forward): filenames are ASCII-only in stage 1 — if the original filename is non-ASCII, emit `Content-Disposition: attachment; filename*=UTF-8''<percent-encoded>` **plus** a plain `filename="<ASCII fallback>"` (RFC 2183 §2 NOTE: "Parameter values longer than 78 characters, or which contain non-ASCII characters, MUST be encoded as specified in [RFC 2184]" (=2231)). Percent-encode every byte outside `attribute-char` (RFC 2231 §7: any US-ASCII CHAR except SPACE, CTLs, `*`, `'`, `%`, or tspecials `()<>@,;:\"/[]?=`).

---

## 3. MIME structure for HTML mail

### 3.1 Structures (exact) **[RFC 2046 §5.1.1, §5.1.3, §5.1.4; RFC 2387 §3]**

```
A) text + HTML, no attachments (reply-all, forward without attachments):
   multipart/alternative
     ├─ text/plain; charset="UTF-8"   (quoted-printable)
     └─ text/html;  charset="UTF-8"   (quoted-printable)

B) with attachments (forward with PDF):
   multipart/mixed
     ├─ multipart/alternative  (as A)
     └─ application/pdf; name="x.pdf"  Content-Disposition: attachment; filename="x.pdf"  (base64)

C) only if inline cid: images exist (NOT used by minimail stage 1 — see 3.4):
   multipart/mixed
     ├─ multipart/related; type="multipart/alternative"
     │    ├─ multipart/alternative (as A)
     │    └─ image/png  Content-ID: <ii_xxx>  Content-Disposition: inline; filename="image.png" (base64)
     └─ application/pdf ...
```
- `multipart/alternative`: "the alternatives appear in an order of increasing faithfulness to the original content. In general, the best choice is the LAST part" ⇒ **text/plain first, text/html last** (RFC 2046 §5.1.4).
- `multipart/mixed`: parts "are independent and need to be bundled in a particular order"; unknown multipart subtypes are treated as mixed (§5.1.3).
- `multipart/related` (RFC 2387 §3): root = first part unless `start=` given; `type` parameter "must be specified and its value is the MIME media type of the "root" body part". Gmail's own structure for an inline image is `multipart/related` → [`multipart/alternative`, `image/png` with `Content-ID: <ii_jukb4ame0>`, `X-Attachment-Id: ii_jukb4ame0`, `Content-Disposition: attachment; filename="image.png"`] and `<img src="cid:ii_jukb4ame0">` in the HTML **[FIXTURE gyb 16a281480109495b.eml]** — note Gmail marks the image `attachment`, not `inline`, and relies on `multipart/related`. Google's CLI notes: "Gmail's API rewrites `Content-Disposition: inline` to `attachment` when parts sit in `multipart/mixed`, so the explicit `multipart/related` structure is required" **[GWS-CLI mod.rs `finalize_message`]**.

### 3.2 Boundaries **[RFC 2046 §5.1.1]**

- `boundary := 0*69<bchars> bcharsnospace`, `bcharsnospace := DIGIT / ALPHA / "'" / "(" / ")" / "+" / "_" / "," / "-" / "." / "/" / ":" / "=" / "?"`; 1–70 chars, must not end in a space; "Boundary delimiters must not appear within the encapsulated material".
- Delimiter = `CRLF "--" boundary`; close = `CRLF "--" boundary "--"`; "The boundary delimiter MUST occur at the beginning of a line, i.e., following a CRLF, and the initial CRLF is considered to be attached to the boundary delimiter line rather than part of the preceding part". Hence a part that must end with a line break needs **two** CRLFs before the delimiter. Quote the parameter value: `boundary="..."` ("never hurts").
- Nested multiparts MUST use different boundaries.
- Generation: RFC 2045 §6.7 tip: "choose a boundary that includes a character sequence such as "=_" which can never appear in a quoted-printable body". Use `"=_minimail_" + kind + "_" + 16 hex chars from SystemRandomNumberGenerator` (e.g. `=_minimail_alt_7c1e3f2a9b4d4e6f`, 32 chars) — `=` and `_` are `bcharsnospace`; the `=_` prefix cannot occur in QP output; for base64 parts `_` and `=` mid-line cannot occur either (`=` only as trailing pad, never followed by `_`). No prescan needed.

### 3.3 Content-Transfer-Encoding choice **[RFC 2045 §6.1, §6.2, §6.7, §6.8; RFC 2046 §4.1.1, §4.1.2]**

- Default is `7bit` when the header is absent; "Labelling unencoded data containing 8bit characters as "7bit" is not allowed" (§6.2). `7bit`/`8bit` are identity encodings limited to lines ≤ 998 octets (SMTP "lines no longer than 1000 characters including any trailing CRLF", §6). `8bit` needs an 8BITMIME transport (Gmail supports it, but `raw` is opaque to us and HTML lines are routinely > 998 chars) ⇒ **never use 7bit/8bit for bodies we generate**.
- **text/plain and text/html (UTF-8): use `quoted-printable`** — this is what Gmail itself emits for both parts **[FIXTURE reply-ctf, sample-315]**. Rules (§6.7): (1) any octet may be `=XX`, hex digits **uppercase**; (2) octets 33–60 and 62–126 may be literal (i.e. everything printable except `=`); (3) TAB/SPACE literal except at end of line → `=09`/`=20`; (4) CRLF stays CRLF; (5) encoded lines ≤ **76** chars — soft break = `=` as the last char (the 76 counts the `=`, not the CRLF). Decoder: strip trailing whitespace per line, `=`+CRLF = nothing, `=XX` → byte; be tolerant of lowercase hex and lone `=` (Gmail is lenient).
- **Binary attachments: `base64`** — RFC 2045 §6.8: standard alphabet (`+`,`/`, `=` pad), "The encoded output stream must be represented in lines of no more than 76 characters each" — i.e. 76 chars + CRLF (this is **standard** base64, NOT base64url; the whole message is then base64url-encoded once more into `raw`). Swift: `data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])`.
- Charset: `Content-Type: text/plain; charset="UTF-8"` (value case-insensitive, quoting optional; Gmail writes `charset="UTF-8"`). RFC 2046 §4.1.1: "The canonical form of any MIME "text" subtype MUST always represent a line break as a CRLF sequence" — normalise `\n`/`\r` in user text to CRLF **before** QP encoding.
- Attachment part headers: `Content-Type: <mime>; name="<file>"` + `Content-Disposition: attachment; filename="<file>"; size=<octets>` (RFC 2183 §2.2, §2.3, §2.7; `size` is optional) + `Content-Transfer-Encoding: base64`. Unknown MIME ⇒ `application/octet-stream`.

### 3.4 Images in the HTML signature — recommendation: **hosted `https://` image**

| Option | Verdict | Why |
|---|---|---|
| `data:image/png;base64,…` URI in `<img src>` | **No** | Gmail web/mobile do not render `data:` images (shows a broken image or the raw text): **[SNIPPET: support.google.com/mail/thread/120618835 "why is BASE64 image not rendering through gmail website while it is through outlook", experts-exchange, w3tutorials.net, SuiteCRM#9248, labnol.org "Gmail does not support base64 images in HTML emails"]**. Outlook/Apple Mail do render them. Not byte-verified against a Google doc, but consistently reported since ~2016. |
| `cid:` + `multipart/related` | Works everywhere, including Gmail | Every reply/forward becomes structure C (3.1) with an extra ~30–100 KB base64 part; the image shows as an attachment in some clients (Gmail marks it `Content-Disposition: attachment` itself); adds parser and builder complexity. Reasonable **stage-2** option if the owner wants a logo that renders with remote images blocked. |
| Hosted `https://www.newtelco.de/…/logo.png` | **Recommended for stage 1** | Zero MIME complexity; Gmail proxies and shows hosted images by default; Gmail's own signature editor only accepts a web URL or a Drive image **[SNIPPET: support.google.com/mail/answer/8395 — blocked, UNVERIFIED wording]**; the `sendAs.signature` HTML from Gmail will already contain such URLs. Downsides: recipients with "block remote images" see alt text (use `alt=""` or the company name), and HTTPS is mandatory (Gmail blocks `http:` images **[SNIPPET]**). |

Signature markup convention (what Gmail emits, so quote-strippers/`gmail_signature` detectors behave) **[FIXTURE sample-546.eml, smores-react story]**:
```html
<span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">…signature HTML…</div>
```
Plain-text counterpart: a line consisting of exactly `-- ` (dash dash space) before the signature (usenet/RFC 3676 §4.3 convention; RFC 3676 text not available here — UNVERIFIED citation, the convention itself is universal). Note QP must encode that trailing space as `--=20` (RFC 2045 §6.7 rule 3) — see §7.1.

### 3.5 Default font / colour for outgoing HTML

Wrap the user-typed part only: `<div dir="ltr" style="font-family:Helvetica,Arial,sans-serif;font-size:14px;color:#1d1d1f">…</div>` (Gmail uses inline styles on a `div`, e.g. `style="font-family:Arial,sans-serif;font-size:14px;color:rgb(0,0,0)"` **[FIXTURE reply-ctf]**). Do not wrap the quoted original or the signature (they carry their own styling). Escape `&<>"'` in user text and convert `\n` → `<br>` (Google CLI `resolve_html_body`: `html_escape(text).lines().join("<br>\r\n")`).

---

## 4. Quoting the original

### 4.1 Reply — Gmail conventions **[FIXTURE reply-ctf 2025, talon 2012/2014, GWS-CLI reply.rs]**

Attribution line (exact, current Gmail): `On Wed, May 7, 2025 at 8:02\u{202F}PM Alex Thorndale <thorndalealex@gmail.com> wrote:` — format `On {EEE, MMM d, yyyy 'at' h:mm}{U+202F}{a} {Name} <{addr}> wrote:`. Points: **U+202F NARROW NO-BREAK SPACE** before `AM`/`PM` (appears as `=E2=80=AF` in QP — Gmail has emitted this since ~2023; Google's CLI reproduces it: `"%a, %b %-d, %Y at %-I:%M\u{202f}%p"`), no comma between date and name (pre-2020 Gmail had `..., Name <addr> wrote:`), date in the **sender's local time**, English weekday/month names regardless of locale (use `Locale(identifier: "en_US_POSIX")`), 12-hour clock without leading zero. Localised Gmail UIs emit localised text (`Am Do., 18. März 2024 um 06:30 Uhr schrieb …`), but English is the safe interoperable choice.

HTML (exact skeleton, Gmail 2023+):
```html
<br><div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On Thu, Sep 10, 2026 at 9:12 AM Alice Müller &lt;<a href="mailto:alice@example.com">alice@example.com</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">ORIGINAL_HTML_BODY</blockquote></div>
```
(older Gmail: `<div class="gmail_quote">On … wrote:<br><blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">`; both class names must be present for Gmail/talon/other quote-collapsers: `gmail_quote_container` (wrapper, 2023+), `gmail_attr` (attribution), `gmail_quote` (blockquote).) `ORIGINAL_HTML_BODY` = the original's `text/html` part **after sanitising** (strip `<script>`, `<style>` is OK, drop `<html>/<head>/<body>` wrappers, keep the original's own nested `gmail_quote` blocks — Gmail nests them). If the original has only `text/plain`: `html_escape(text)` with `\n` → `<br>` (Google CLI `resolve_html_body`).

Plain text: attribution line, then every original line prefixed with `> ` (`>` alone for empty lines — Gmail emits `>` then the line; both `> ` and `>` are seen in fixtures; use `> ` for non-empty and `>` for empty lines — exactly what §7.1 shows and what the CTF fixture shows). Gmail additionally wraps at ~72 columns; not required. Layout (Gmail): user text, blank line, `-- `/signature, blank line, attribution, quoted lines.

### 4.2 Forward — Gmail conventions **[FIXTURE sample-315 (Gmail web, EN), invoiceninja fixture (Gmail web, DE), GWS-CLI forward.rs]**

Plain text (exact bytes Gmail web produces; blank line, then the block, then **three** blank lines before the body in Gmail's output — one blank line is enough):
```
---------- Forwarded message ---------
From: Alice Müller <alice@example.com>
Date: Thu, Sep 10, 2026 at 9:12 AM
Subject: Angebot für die Erweiterung
To: Max Mustermann <max.mustermann@newtelco.de>
Cc: Carol Chen <carol@partner.example>


<original plain text>
```
Exact banner: 10 hyphens, space, `Forwarded message`, space, **9** hyphens (`---------- Forwarded message ---------`). Some third-party code uses 10 trailing hyphens; Gmail uses 9 (both fixtures). Header order `From`, `Date`, `Subject`, `To`, then `Cc` only if present (Gmail web omits `Cc:` when empty; when present it follows `To:` — UNVERIFIED for Gmail web, Google CLI puts `Cc` after `To`). The `Date:` uses the same human format as the reply attribution.

HTML (exact skeleton Gmail web emits):
```html
<br><div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>From: <strong class="gmail_sendername" dir="auto">Alice Müller</strong> <span dir="auto">&lt;<a href="mailto:alice@example.com">alice@example.com</a>&gt;</span><br>Date: Thu, Sep 10, 2026 at 9:12 AM<br>Subject: Angebot für die Erweiterung<br>To: Max Mustermann &lt;<a href="mailto:max.mustermann@newtelco.de">max.mustermann@newtelco.de</a>&gt;<br>Cc: Carol Chen &lt;<a href="mailto:carol@partner.example">carol@partner.example</a>&gt;<br></div><br><br>ORIGINAL_HTML_BODY</div>
```
(Gmail 2023 fixture uses `<b class="gmail_sendername" dir="auto">`, 2024 fixture `<strong …>`; either is fine.) The forwarded body is **not** inside a `<blockquote>`. The forwarder's note (if any) and the signature come **before** the block.

---

## 5. Parsing incoming Gmail payloads (`format=full`)

### 5.1 Data model **[DISC]** (verbatim descriptions)

- `MessagePart`: `partId` "The immutable ID of the message part."; `mimeType`; `filename` "The filename of the attachment. Only present if this message part represents an attachment."; `headers[] {name, value}` ("For the top-level message part … it will contain the standard RFC 2822 email headers such as `To`, `From`, and `Subject`."); `body` (`MessagePartBody`) "which may be empty for container MIME message parts."; `parts[]` "The child MIME message parts of this part. This only applies to container MIME message parts, for example `multipart/*`. For non- container MIME message part types, such as `text/plain`, this field is empty."
- `MessagePartBody`: `attachmentId` "When present, contains the ID of an external attachment that can be retrieved in a separate `messages.attachments.get` request. When not present, the entire content of the message part body is contained in the data field."; `size` (int32) "Number of bytes for the message part data (encoding notwithstanding)."; `data` "The body data of a MIME message part as a base64url encoded string. May be empty for MIME container types that have no message body or when the body data is sent as a separate attachment. An attachment ID is present if the body data is contained in a separate attachment."
- `users.messages.attachments.get`: `GET gmail/v1/users/{userId}/messages/{messageId}/attachments/{id}` → `MessagePartBody` (`size`, `data`); scopes include `gmail.modify`.

**Is `data` already CTE-decoded?** The schema says only "body data … as a base64url encoded string" and `size` is "encoding notwithstanding". Google's own CLI decodes text parts with `URL_SAFE.decode(data)` then `String::from_utf8(decoded)` directly — no quoted-printable/base64 step — and decodes attachments the same way and writes the bytes straight into new MIME parts **[GWS-CLI mod.rs `decode_text_body`, `fetch_attachment_data`]**. So: **yes — `data` = base64url(decoded part bytes)**; the wire `Content-Transfer-Encoding` has already been removed by Gmail. What is *not* removed is the **charset**: the bytes are in the part's `Content-Type; charset=…` (Google's CLI assumes UTF-8 and warns otherwise; minimail must honour the charset — see 5.3). Mark: [GWS-CLI-verified behaviour, not documented prose].

### 5.2 Walking the tree — choosing the body

```
func collect(part, ctx):
    ct  = part.mimeType.lowercased()
    cid = header(part, "Content-ID")          // "<ii_abc>" — strip <> for the map key
    disp = header(part, "Content-Disposition")?.lowercased()
    if part.body.attachmentId != nil:          // any fetchable blob: attachment or inline image or big text part
        if ct.hasPrefix("text/") && part.filename.isEmpty && cid == nil:
            ctx.deferredText.append(part)      // large text body delivered as attachment (DISC: "or when the body data is sent as a separate attachment")
        else if cid != nil && !(disp?.hasPrefix("attachment") ?? false):
            ctx.inline[cid] = part             // candidate for cid: rewriting; Gmail gives Content-IDs to regular attachments too, so check disposition [GWS-CLI]
            ctx.attachments.append(part)       // still list it (Gmail web shows inline images as attachments too)
        else:
            ctx.attachments.append(part)
        return                                 // do NOT recurse into message/rfc822 attachments [GWS-CLI]
    if ct == "multipart/alternative":
        // pick the best alternative we can render: last text/html, else last text/plain, else recurse into the last multipart child
        for child in part.parts: collect(child, ctx)   // simplest: recurse; the html/plain slots below take the first html found and first plain found
    else if ct.hasPrefix("multipart/"):        // mixed, related, report, signed, …
        for child in part.parts: collect(child, ctx)
    else if ct == "text/html" && ctx.html == nil && part.filename.isEmpty: ctx.html = decodeText(part)
    else if ct == "text/plain" && ctx.plain == nil && part.filename.isEmpty: ctx.plain = decodeText(part)
    else if part.body.data != nil && !part.filename.isEmpty: ctx.attachments.append(part)   // small attachment delivered inline in data (rare)
```
Rules distilled from RFC 2046 §5.1.4 ("Receiving user agents should pick and display the last format they are capable of displaying") and Google's CLI (`extract_payload_recursive`: first `text/plain` and first `text/html` body-text parts win; body-text part = has `data`, no `attachmentId`, empty `filename`, no `Content-ID`). Common shapes to unit-test: (a) bare `text/plain` or `text/html` at top level (`payload.parts` absent, `payload.body.data` present); (b) `multipart/alternative` [plain, html]; (c) `multipart/mixed` [ `multipart/alternative` [plain, html], `application/pdf` ]; (d) `multipart/related` [ `multipart/alternative` [plain, html], `image/png` cid ] (Gmail inline image); (e) `multipart/mixed` [ `multipart/related` [ `multipart/alternative` [...], image ], pdf ] (Outlook); (f) `multipart/signed` [ `multipart/mixed` [...], `application/pkcs7-signature` ]; (g) `multipart/report`/`message/delivery-status`; (h) `text/html` with `attachmentId` and no `data` (large body).

Prefer `html` when present (render in WKWebView), else `plain` wrapped in `<pre style="white-space:pre-wrap">` with HTML-escaping and linkified URLs. Cache both in `message.body_html/body_text`.

### 5.3 Decoding a text part

1. `bytes = base64urlDecode(part.body.data)` (tolerant decoder from §1.2).
2. `charset` = parameter of the part's `Content-Type` header (case-insensitive param name and value; strip quotes; default `us-ascii` per RFC 2046 §4.1.2 — in practice treat missing as UTF-8). Map with `CFStringConvertIANACharSetNameToEncoding(charset as CFString)` → `CFStringConvertEncodingToNSStringEncoding` → `String(data:encoding:)`; if that fails, fall back to `.utf8`, then `.isoLatin1` (never fails).
3. Text parts may still contain a `<meta charset=…>` that disagrees; the MIME header wins.
4. Normalise line endings to `\n` for storage.

### 5.4 Inline `cid:` images → rewrite or block

- Map key: `Content-ID` header value without `<>` (RFC 2392 §2: a cid URL "is converted to the corresponding Content-ID message header by removing the "cid:" prefix, converting the % encoded character to their equivalent US-ASCII characters, and enclosing the remaining parts with an angle bracket pair"). When matching `src="cid:X"`, percent-decode `X` first; Gmail's ids are `ii_<base36>` / `<uuid>@<host>`.
- Regex-free approach: run the sanitiser over the HTML (already planned) and, for each `<img src="cid:...">`, either (a) **stage 1**: replace `src` with a 1×1 transparent `data:` GIF and set `data-cid` (WKWebView, unlike Gmail, renders `data:` URIs fine — the Gmail restriction in 3.4 is about *sending*), or (b) on demand ("Load images" button, or automatically since cid images are not tracking pixels — recommended): call `attachments.get` for `inline[cid].body.attachmentId`, then `src = "data:\(mimeType);base64,\(bytes.base64EncodedString())"`. Cache the rewritten HTML. Do this only for parts referenced by the HTML; unreferenced `Content-ID` parts stay in the attachment list.
- Gmail sometimes serves inline images with `Content-Disposition: attachment` and a `Content-ID` (see fixture) — the HTML reference, not the disposition, decides whether it is inline.
- `attachmentId` values are long and not guaranteed stable across `messages.get` calls (UNVERIFIED, community-reported) — resolve from a fresh `messages.get` when needed.

### 5.5 Headers to decode on ingest

`From`, `To`, `Cc`, `Reply-To` (§2.2 parser + RFC 2047), `Subject` (RFC 2047, unstructured — decode encoded-words anywhere in the string, dropping LWSP between adjacent encoded-words), `Date` (RFC 5322 §3.3 with obsolete forms: 2-digit years, `GMT`/`EST` zone names, missing seconds, extra parenthesised comments `(CEST)`; prefer `internalDate` for ordering), `Message-ID`, `In-Reply-To`, `References` (split on whitespace after unfolding; keep `<…>` tokens only; Gmail may fold `References` across many lines), `Content-Type` (params), `List-Unsubscribe` (optional). Header names are case-insensitive (`Message-Id` vs `Message-ID` — Gmail emits `Message-ID`, other MUAs `Message-Id`).

---

## 6. Forwarding attachments **[DISC + GWS-CLI]**

Original attachments are **not** referenced by id in `messages.send`; the raw message must physically contain them. Procedure (Google's CLI does exactly this, `fetch_original_parts` → `finalize_message`):
1. From the cached parse (§5.2) take `ctx.attachments` (skip `message/rfc822` and — in stage 1 — skip inline `cid:` images; Google's CLI skips inline images in plain-text mode "matching Gmail web" and includes them via `multipart/related` in HTML mode).
2. For each: `GET gmail/v1/users/me/messages/{originalMessageId}/attachments/{attachmentId}` → `data` → `base64urlDecode` → bytes (verify `bytes.count == part.body.size`; the API returns the full blob in one response — no ranges).
3. Build structure B (§3.1): each attachment becomes a part with `Content-Type: <part.mimeType>; name="<filename>"`, `Content-Disposition: attachment; filename="<filename>"; size=<n>` (RFC 2231 form for non-ASCII names, §2.4), `Content-Transfer-Encoding: base64` (76-col lines, standard alphabet). Preserve the original order and filenames (`part.filename` is already decoded by Gmail; sanitise `/`, `\`, control chars, leading `.`).
4. Size budget: JSON `raw` inflates bytes by 4/3 for base64 lines plus 4/3 again for base64url; Gmail's total limit is 35 MB per message **[SNIPPET: gmass/getinboxzero, and DISC `mediaUpload.maxSize = 36700160` for the upload path]** ⇒ refuse to forward if `Σ size · 1.37 + body > 25 MB` (Gmail web's own 25 MB attachment cap **[SNIPPET]**) and tell the user. Prefer the media-upload path (§1.1) when the sum exceeds ~5 MB.
5. Do not re-download attachments the user removed in the compose UI; fetch lazily at send time in the outbox worker (attachments are never prefetched — PLAN.md).

---

## 7. Byte-exact example messages

Both were generated by a script (`/tmp/claude-0/…/scratchpad/gen/gen.py`, output files `reply.eml`, `forward.eml`) and round-tripped through Python's `email` parser (parts decode back to the source strings, PDF bytes identical, `In-Reply-To` absent on the forward). **Every line ends with CRLF**; the rendering below shows `\r\n` as line breaks. The SHA-256 is over the exact CRLF bytes — use it in `MIMEBuilderTests` to pin the builder. The `raw` values are base64url **without** padding (both happen to need exactly one `=` if you emit padded output, since 3035 % 4 == 3 and 3903 % 4 == 3).

Fixed inputs used by both: `Date` frozen; `Message-ID` from fixed UUIDs; boundaries fixed; attribution date `Thu, Sep 10, 2026 at 9:12\u{202F}AM` (**U+202F** before `AM`, shown as `=E2=80=AF`); signature HTML/text as in §3.4; original body HTML `<div dir="ltr">Hallo Max,<div><br></div><div>ist das Angebot für die Erweiterung schon unterwegs?</div><div><br></div><div>Gruß<br>Alice</div></div>` and plain text `Hallo Max,\r\n\r\nist das Angebot für die Erweiterung schon unterwegs?\r\n\r\nGruß\r\nAlice`; original headers `From: Alice Müller <alice@example.com>`, `To: Max Mustermann <max.mustermann@newtelco.de>, bob@example.com`, `Cc: Carol Chen <carol@partner.example>`, `Subject: Angebot für die Erweiterung`, `Message-ID: <CAF=abc123@mail.example.com>`, `References: <older-id@example.com>`, `Date: Thu, 10 Sep 2026 09:12:33 +0200`; self = `max.mustermann@newtelco.de`.

### 7.1 Reply-all (multipart/alternative, HTML + plain, signature, quoted original) — 2276 bytes, `sha256 = b9f8078c1d50352b00f1486624bb2247ec19587ccf388b652aed62da0d1fcbd3`

```
From: Max Mustermann <max.mustermann@newtelco.de>
To: =?UTF-8?B?QWxpY2UgTcO8bGxlcg==?= <alice@example.com>, bob@example.com
Cc: Carol Chen <carol@partner.example>
Subject: =?UTF-8?B?UmU6IEFuZ2Vib3QgZsO8ciBkaWUgRXJ3ZWl0ZXJ1bmc=?=
Date: Fri, 11 Sep 2026 10:00:00 +0200
Message-ID: <7C1E3F2A-9B4D-4E6F-8A10-2B3C4D5E6F70@newtelco.de>
In-Reply-To: <CAF=abc123@mail.example.com>
References: <older-id@example.com> <CAF=abc123@mail.example.com>
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="=_minimail_alt_7c1e3f2a9b4d4e6f"

--=_minimail_alt_7c1e3f2a9b4d4e6f
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

Hallo Alice,

ja, das Angebot geht heute noch raus.

Viele Gr=C3=BC=C3=9Fe
Max

--=20
Max Mustermann
newtelco GmbH
https://www.newtelco.de

On Thu, Sep 10, 2026 at 9:12=E2=80=AFAM Alice M=C3=BCller <alice@example.co=
m> wrote:
> Hallo Max,
>
> ist das Angebot f=C3=BCr die Erweiterung schon unterwegs?
>
> Gru=C3=9F
> Alice

--=_minimail_alt_7c1e3f2a9b4d4e6f
Content-Type: text/html; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

<div dir=3D"ltr" style=3D"font-family:Helvetica,Arial,sans-serif;font-size:=
14px;color:#1d1d1f">Hallo Alice,<div><br></div><div>ja, das Angebot geht he=
ute noch raus.</div><div><br></div><div>Viele Gr=C3=BC=C3=9Fe<br>Max</div><=
div><br></div><span class=3D"gmail_signature_prefix">-- </span><br><div cla=
ss=3D"gmail_signature"><div style=3D"font-family:Helvetica,Arial,sans-serif=
;font-size:13px;color:#222222">Max Mustermann<br>newtelco GmbH<br><a href=
=3D"https://www.newtelco.de">www.newtelco.de</a></div></div></div><br><div =
class=3D"gmail_quote gmail_quote_container"><div dir=3D"ltr" class=3D"gmail=
_attr">On Thu, Sep 10, 2026 at 9:12=E2=80=AFAM Alice M=C3=BCller &lt;<a hre=
f=3D"mailto:alice@example.com">alice@example.com</a>&gt; wrote:<br></div><b=
lockquote class=3D"gmail_quote" style=3D"margin:0px 0px 0px 0.8ex;border-le=
ft:1px solid rgb(204,204,204);padding-left:1ex"><div dir=3D"ltr">Hallo Max,=
<div><br></div><div>ist das Angebot f=C3=BCr die Erweiterung schon unterweg=
s?</div><div><br></div><div>Gru=C3=9F<br>Alice</div></div></blockquote></di=
v>

--=_minimail_alt_7c1e3f2a9b4d4e6f--
```
Things to notice: `--=20` (trailing space of the `-- ` separator, RFC 2045 §6.7 rule 3); `=E2=80=AF` (U+202F); soft breaks `=` at column 76; the `</div>` before `wrote:` line breaks; the empty line before each `--boundary` is the part's own final CRLF (the body ends with CRLF) plus the CRLF that belongs to the delimiter (RFC 2046 §5.1.1); no `Content-Transfer-Encoding` on the container; `To:` display name RFC 2047-B-encoded, addr-spec bare.

JSON body: `{"threadId":"<original threadId>","raw":"<the string below>"}`. `raw` (base64url, no padding, 3035 chars):
```
RnJvbTogTWF4IE11c3Rlcm1hbm4gPG1heC5tdXN0ZXJtYW5uQG5ld3RlbGNvLmRlPg0KVG86ID0_VVRGLTg_Qj9RV3hwWTJVZ1RjTzhiR3hsY2c9PT89IDxhbGljZUBleGFtcGxlLmNvbT4sIGJvYkBleGFtcGxlLmNvbQ0KQ2M6IENhcm9sIENoZW4gPGNhcm9sQHBhcnRuZXIuZXhhbXBsZT4NClN1YmplY3Q6ID0_VVRGLTg_Qj9VbVU2SUVGdVoyVmliM1FnWnNPOGNpQmthV1VnUlhKM1pXbDBaWEoxYm1jPT89DQpEYXRlOiBGcmksIDExIFNlcCAyMDI2IDEwOjAwOjAwICswMjAwDQpNZXNzYWdlLUlEOiA8N0MxRTNGMkEtOUI0RC00RTZGLThBMTAtMkIzQzRENUU2RjcwQG5ld3RlbGNvLmRlPg0KSW4tUmVwbHktVG86IDxDQUY9YWJjMTIzQG1haWwuZXhhbXBsZS5jb20-DQpSZWZlcmVuY2VzOiA8b2xkZXItaWRAZXhhbXBsZS5jb20-IDxDQUY9YWJjMTIzQG1haWwuZXhhbXBsZS5jb20-DQpNSU1FLVZlcnNpb246IDEuMA0KQ29udGVudC1UeXBlOiBtdWx0aXBhcnQvYWx0ZXJuYXRpdmU7IGJvdW5kYXJ5PSI9X21pbmltYWlsX2FsdF83YzFlM2YyYTliNGQ0ZTZmIg0KDQotLT1fbWluaW1haWxfYWx0XzdjMWUzZjJhOWI0ZDRlNmYNCkNvbnRlbnQtVHlwZTogdGV4dC9wbGFpbjsgY2hhcnNldD0iVVRGLTgiDQpDb250ZW50LVRyYW5zZmVyLUVuY29kaW5nOiBxdW90ZWQtcHJpbnRhYmxlDQoNCkhhbGxvIEFsaWNlLA0KDQpqYSwgZGFzIEFuZ2Vib3QgZ2VodCBoZXV0ZSBub2NoIHJhdXMuDQoNClZpZWxlIEdyPUMzPUJDPUMzPTlGZQ0KTWF4DQoNCi0tPTIwDQpNYXggTXVzdGVybWFubg0KbmV3dGVsY28gR21iSA0KaHR0cHM6Ly93d3cubmV3dGVsY28uZGUNCg0KT24gVGh1LCBTZXAgMTAsIDIwMjYgYXQgOToxMj1FMj04MD1BRkFNIEFsaWNlIE09QzM9QkNsbGVyIDxhbGljZUBleGFtcGxlLmNvPQ0KbT4gd3JvdGU6DQo-IEhhbGxvIE1heCwNCj4NCj4gaXN0IGRhcyBBbmdlYm90IGY9QzM9QkNyIGRpZSBFcndlaXRlcnVuZyBzY2hvbiB1bnRlcndlZ3M_DQo-DQo-IEdydT1DMz05Rg0KPiBBbGljZQ0KDQotLT1fbWluaW1haWxfYWx0XzdjMWUzZjJhOWI0ZDRlNmYNCkNvbnRlbnQtVHlwZTogdGV4dC9odG1sOyBjaGFyc2V0PSJVVEYtOCINCkNvbnRlbnQtVHJhbnNmZXItRW5jb2Rpbmc6IHF1b3RlZC1wcmludGFibGUNCg0KPGRpdiBkaXI9M0QibHRyIiBzdHlsZT0zRCJmb250LWZhbWlseTpIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZjtmb250LXNpemU6PQ0KMTRweDtjb2xvcjojMWQxZDFmIj5IYWxsbyBBbGljZSw8ZGl2Pjxicj48L2Rpdj48ZGl2PmphLCBkYXMgQW5nZWJvdCBnZWh0IGhlPQ0KdXRlIG5vY2ggcmF1cy48L2Rpdj48ZGl2Pjxicj48L2Rpdj48ZGl2PlZpZWxlIEdyPUMzPUJDPUMzPTlGZTxicj5NYXg8L2Rpdj48PQ0KZGl2Pjxicj48L2Rpdj48c3BhbiBjbGFzcz0zRCJnbWFpbF9zaWduYXR1cmVfcHJlZml4Ij4tLSA8L3NwYW4-PGJyPjxkaXYgY2xhPQ0Kc3M9M0QiZ21haWxfc2lnbmF0dXJlIj48ZGl2IHN0eWxlPTNEImZvbnQtZmFtaWx5OkhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmPQ0KO2ZvbnQtc2l6ZToxM3B4O2NvbG9yOiMyMjIyMjIiPk1heCBNdXN0ZXJtYW5uPGJyPm5ld3RlbGNvIEdtYkg8YnI-PGEgaHJlZj0NCj0zRCJodHRwczovL3d3dy5uZXd0ZWxjby5kZSI-d3d3Lm5ld3RlbGNvLmRlPC9hPjwvZGl2PjwvZGl2PjwvZGl2Pjxicj48ZGl2ID0NCmNsYXNzPTNEImdtYWlsX3F1b3RlIGdtYWlsX3F1b3RlX2NvbnRhaW5lciI-PGRpdiBkaXI9M0QibHRyIiBjbGFzcz0zRCJnbWFpbD0NCl9hdHRyIj5PbiBUaHUsIFNlcCAxMCwgMjAyNiBhdCA5OjEyPUUyPTgwPUFGQU0gQWxpY2UgTT1DMz1CQ2xsZXIgJmx0OzxhIGhyZT0NCmY9M0QibWFpbHRvOmFsaWNlQGV4YW1wbGUuY29tIj5hbGljZUBleGFtcGxlLmNvbTwvYT4mZ3Q7IHdyb3RlOjxicj48L2Rpdj48Yj0NCmxvY2txdW90ZSBjbGFzcz0zRCJnbWFpbF9xdW90ZSIgc3R5bGU9M0QibWFyZ2luOjBweCAwcHggMHB4IDAuOGV4O2JvcmRlci1sZT0NCmZ0OjFweCBzb2xpZCByZ2IoMjA0LDIwNCwyMDQpO3BhZGRpbmctbGVmdDoxZXgiPjxkaXYgZGlyPTNEImx0ciI-SGFsbG8gTWF4LD0NCjxkaXY-PGJyPjwvZGl2PjxkaXY-aXN0IGRhcyBBbmdlYm90IGY9QzM9QkNyIGRpZSBFcndlaXRlcnVuZyBzY2hvbiB1bnRlcndlZz0NCnM_PC9kaXY-PGRpdj48YnI-PC9kaXY-PGRpdj5HcnU9QzM9OUY8YnI-QWxpY2U8L2Rpdj48L2Rpdj48L2Jsb2NrcXVvdGU-PC9kaT0NCnY-DQoNCi0tPV9taW5pbWFpbF9hbHRfN2MxZTNmMmE5YjRkNGU2Zi0tDQo
```

### 7.2 Forward with one PDF attachment (multipart/mixed ⊃ multipart/alternative + application/pdf) — 2927 bytes, `sha256 = 2127dc5426a76d3deb405f04f30b602d22461af3b8ea6dbdee8d494d66429261`

PDF bytes (125 octets, a minimal valid-looking stub): `%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n`.

```
From: Max Mustermann <max.mustermann@newtelco.de>
To: Dave Davis <dave@newtelco.de>
Subject: =?UTF-8?B?RndkOiBBbmdlYm90IGbDvHIgZGllIEVyd2VpdGVydW5n?=
Date: Fri, 11 Sep 2026 10:05:00 +0200
Message-ID: <0F1E2D3C-4B5A-4968-8778-695A4B3C2D1E@newtelco.de>
References: <older-id@example.com> <CAF=abc123@mail.example.com>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="=_minimail_mixed_0b1c2d3e4f5a6b7c"

--=_minimail_mixed_0b1c2d3e4f5a6b7c
Content-Type: multipart/alternative; boundary="=_minimail_alt_1a2b3c4d5e6f7a8b"

--=_minimail_alt_1a2b3c4d5e6f7a8b
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

FYI, siehe Anhang.

--=20
Max Mustermann
newtelco GmbH
https://www.newtelco.de

---------- Forwarded message ---------
From: Alice M=C3=BCller <alice@example.com>
Date: Thu, Sep 10, 2026 at 9:12=E2=80=AFAM
Subject: Angebot f=C3=BCr die Erweiterung
To: Max Mustermann <max.mustermann@newtelco.de>
Cc: Carol Chen <carol@partner.example>


Hallo Max,

ist das Angebot f=C3=BCr die Erweiterung schon unterwegs?

Gru=C3=9F
Alice

--=_minimail_alt_1a2b3c4d5e6f7a8b
Content-Type: text/html; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

<div dir=3D"ltr" style=3D"font-family:Helvetica,Arial,sans-serif;font-size:=
14px;color:#1d1d1f">FYI, siehe Anhang.<div><br></div><span class=3D"gmail_s=
ignature_prefix">-- </span><br><div class=3D"gmail_signature"><div style=3D=
"font-family:Helvetica,Arial,sans-serif;font-size:13px;color:#222222">Max M=
ustermann<br>newtelco GmbH<br><a href=3D"https://www.newtelco.de">www.newte=
lco.de</a></div></div></div><br><div class=3D"gmail_quote gmail_quote_conta=
iner"><div dir=3D"ltr" class=3D"gmail_attr">---------- Forwarded message --=
-------<br>From: <strong class=3D"gmail_sendername" dir=3D"auto">Alice M=C3=
=BCller</strong> <span dir=3D"auto">&lt;<a href=3D"mailto:alice@example.com=
">alice@example.com</a>&gt;</span><br>Date: Thu, Sep 10, 2026 at 9:12=E2=80=
=AFAM<br>Subject: Angebot f=C3=BCr die Erweiterung<br>To: Max Mustermann &l=
t;<a href=3D"mailto:max.mustermann@newtelco.de">max.mustermann@newtelco.de<=
/a>&gt;<br>Cc: Carol Chen &lt;<a href=3D"mailto:carol@partner.example">caro=
l@partner.example</a>&gt;<br></div><br><br><div dir=3D"ltr">Hallo Max,<div>=
<br></div><div>ist das Angebot f=C3=BCr die Erweiterung schon unterwegs?</d=
iv><div><br></div><div>Gru=C3=9F<br>Alice</div></div></div>

--=_minimail_alt_1a2b3c4d5e6f7a8b--
--=_minimail_mixed_0b1c2d3e4f5a6b7c
Content-Type: application/pdf; name="Angebot-2026-09.pdf"
Content-Disposition: attachment; filename="Angebot-2026-09.pdf"; size=125
Content-Transfer-Encoding: base64

JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyAyIDAgUj4+ZW5kb2JqCjIgMCBv
Ymo8PC9UeXBlL1BhZ2VzL0tpZHNbXS9Db3VudCAwPj5lbmRvYmoKdHJhaWxlcjw8L1Jvb3QgMSAw
IFI+PgolJUVPRgo=
--=_minimail_mixed_0b1c2d3e4f5a6b7c--
```
Things to notice: the inner close-delimiter `--=_minimail_alt_…--` is immediately followed by the outer delimiter (no blank line needed — the CRLF after the close delimiter is the outer delimiter's leading CRLF); the base64 PDF is wrapped at 76 with standard `+`/`/`/`=`; `=E2=80` / `=AFAM` shows a 3-byte UTF-8 sequence split across a soft line break — legal (RFC 2045 §6.7 splits between `=XX` escapes, the decoder joins them); `Cc:` line included because the original had one; **no `In-Reply-To`** (owner's request; see 1.5). `raw` (base64url, no padding, 3903 chars):
```
RnJvbTogTWF4IE11c3Rlcm1hbm4gPG1heC5tdXN0ZXJtYW5uQG5ld3RlbGNvLmRlPg0KVG86IERhdmUgRGF2aXMgPGRhdmVAbmV3dGVsY28uZGU-DQpTdWJqZWN0OiA9P1VURi04P0I_Um5ka09pQkJibWRsWW05MElHYkR2SElnWkdsbElFVnlkMlZwZEdWeWRXNW4_PQ0KRGF0ZTogRnJpLCAxMSBTZXAgMjAyNiAxMDowNTowMCArMDIwMA0KTWVzc2FnZS1JRDogPDBGMUUyRDNDLTRCNUEtNDk2OC04Nzc4LTY5NUE0QjNDMkQxRUBuZXd0ZWxjby5kZT4NClJlZmVyZW5jZXM6IDxvbGRlci1pZEBleGFtcGxlLmNvbT4gPENBRj1hYmMxMjNAbWFpbC5leGFtcGxlLmNvbT4NCk1JTUUtVmVyc2lvbjogMS4wDQpDb250ZW50LVR5cGU6IG11bHRpcGFydC9taXhlZDsgYm91bmRhcnk9Ij1fbWluaW1haWxfbWl4ZWRfMGIxYzJkM2U0ZjVhNmI3YyINCg0KLS09X21pbmltYWlsX21peGVkXzBiMWMyZDNlNGY1YTZiN2MNCkNvbnRlbnQtVHlwZTogbXVsdGlwYXJ0L2FsdGVybmF0aXZlOyBib3VuZGFyeT0iPV9taW5pbWFpbF9hbHRfMWEyYjNjNGQ1ZTZmN2E4YiINCg0KLS09X21pbmltYWlsX2FsdF8xYTJiM2M0ZDVlNmY3YThiDQpDb250ZW50LVR5cGU6IHRleHQvcGxhaW47IGNoYXJzZXQ9IlVURi04Ig0KQ29udGVudC1UcmFuc2Zlci1FbmNvZGluZzogcXVvdGVkLXByaW50YWJsZQ0KDQpGWUksIHNpZWhlIEFuaGFuZy4NCg0KLS09MjANCk1heCBNdXN0ZXJtYW5uDQpuZXd0ZWxjbyBHbWJIDQpodHRwczovL3d3dy5uZXd0ZWxjby5kZQ0KDQotLS0tLS0tLS0tIEZvcndhcmRlZCBtZXNzYWdlIC0tLS0tLS0tLQ0KRnJvbTogQWxpY2UgTT1DMz1CQ2xsZXIgPGFsaWNlQGV4YW1wbGUuY29tPg0KRGF0ZTogVGh1LCBTZXAgMTAsIDIwMjYgYXQgOToxMj1FMj04MD1BRkFNDQpTdWJqZWN0OiBBbmdlYm90IGY9QzM9QkNyIGRpZSBFcndlaXRlcnVuZw0KVG86IE1heCBNdXN0ZXJtYW5uIDxtYXgubXVzdGVybWFubkBuZXd0ZWxjby5kZT4NCkNjOiBDYXJvbCBDaGVuIDxjYXJvbEBwYXJ0bmVyLmV4YW1wbGU-DQoNCg0KSGFsbG8gTWF4LA0KDQppc3QgZGFzIEFuZ2Vib3QgZj1DMz1CQ3IgZGllIEVyd2VpdGVydW5nIHNjaG9uIHVudGVyd2Vncz8NCg0KR3J1PUMzPTlGDQpBbGljZQ0KDQotLT1fbWluaW1haWxfYWx0XzFhMmIzYzRkNWU2ZjdhOGINCkNvbnRlbnQtVHlwZTogdGV4dC9odG1sOyBjaGFyc2V0PSJVVEYtOCINCkNvbnRlbnQtVHJhbnNmZXItRW5jb2Rpbmc6IHF1b3RlZC1wcmludGFibGUNCg0KPGRpdiBkaXI9M0QibHRyIiBzdHlsZT0zRCJmb250LWZhbWlseTpIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZjtmb250LXNpemU6PQ0KMTRweDtjb2xvcjojMWQxZDFmIj5GWUksIHNpZWhlIEFuaGFuZy48ZGl2Pjxicj48L2Rpdj48c3BhbiBjbGFzcz0zRCJnbWFpbF9zPQ0KaWduYXR1cmVfcHJlZml4Ij4tLSA8L3NwYW4-PGJyPjxkaXYgY2xhc3M9M0QiZ21haWxfc2lnbmF0dXJlIj48ZGl2IHN0eWxlPTNEPQ0KImZvbnQtZmFtaWx5OkhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmO2ZvbnQtc2l6ZToxM3B4O2NvbG9yOiMyMjIyMjIiPk1heCBNPQ0KdXN0ZXJtYW5uPGJyPm5ld3RlbGNvIEdtYkg8YnI-PGEgaHJlZj0zRCJodHRwczovL3d3dy5uZXd0ZWxjby5kZSI-d3d3Lm5ld3RlPQ0KbGNvLmRlPC9hPjwvZGl2PjwvZGl2PjwvZGl2Pjxicj48ZGl2IGNsYXNzPTNEImdtYWlsX3F1b3RlIGdtYWlsX3F1b3RlX2NvbnRhPQ0KaW5lciI-PGRpdiBkaXI9M0QibHRyIiBjbGFzcz0zRCJnbWFpbF9hdHRyIj4tLS0tLS0tLS0tIEZvcndhcmRlZCBtZXNzYWdlIC0tPQ0KLS0tLS0tLTxicj5Gcm9tOiA8c3Ryb25nIGNsYXNzPTNEImdtYWlsX3NlbmRlcm5hbWUiIGRpcj0zRCJhdXRvIj5BbGljZSBNPUMzPQ0KPUJDbGxlcjwvc3Ryb25nPiA8c3BhbiBkaXI9M0QiYXV0byI-Jmx0OzxhIGhyZWY9M0QibWFpbHRvOmFsaWNlQGV4YW1wbGUuY29tPQ0KIj5hbGljZUBleGFtcGxlLmNvbTwvYT4mZ3Q7PC9zcGFuPjxicj5EYXRlOiBUaHUsIFNlcCAxMCwgMjAyNiBhdCA5OjEyPUUyPTgwPQ0KPUFGQU08YnI-U3ViamVjdDogQW5nZWJvdCBmPUMzPUJDciBkaWUgRXJ3ZWl0ZXJ1bmc8YnI-VG86IE1heCBNdXN0ZXJtYW5uICZsPQ0KdDs8YSBocmVmPTNEIm1haWx0bzptYXgubXVzdGVybWFubkBuZXd0ZWxjby5kZSI-bWF4Lm11c3Rlcm1hbm5AbmV3dGVsY28uZGU8PQ0KL2E-Jmd0Ozxicj5DYzogQ2Fyb2wgQ2hlbiAmbHQ7PGEgaHJlZj0zRCJtYWlsdG86Y2Fyb2xAcGFydG5lci5leGFtcGxlIj5jYXJvPQ0KbEBwYXJ0bmVyLmV4YW1wbGU8L2E-Jmd0Ozxicj48L2Rpdj48YnI-PGJyPjxkaXYgZGlyPTNEImx0ciI-SGFsbG8gTWF4LDxkaXY-PQ0KPGJyPjwvZGl2PjxkaXY-aXN0IGRhcyBBbmdlYm90IGY9QzM9QkNyIGRpZSBFcndlaXRlcnVuZyBzY2hvbiB1bnRlcndlZ3M_PC9kPQ0KaXY-PGRpdj48YnI-PC9kaXY-PGRpdj5HcnU9QzM9OUY8YnI-QWxpY2U8L2Rpdj48L2Rpdj48L2Rpdj4NCg0KLS09X21pbmltYWlsX2FsdF8xYTJiM2M0ZDVlNmY3YThiLS0NCi0tPV9taW5pbWFpbF9taXhlZF8wYjFjMmQzZTRmNWE2YjdjDQpDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL3BkZjsgbmFtZT0iQW5nZWJvdC0yMDI2LTA5LnBkZiINCkNvbnRlbnQtRGlzcG9zaXRpb246IGF0dGFjaG1lbnQ7IGZpbGVuYW1lPSJBbmdlYm90LTIwMjYtMDkucGRmIjsgc2l6ZT0xMjUNCkNvbnRlbnQtVHJhbnNmZXItRW5jb2Rpbmc6IGJhc2U2NA0KDQpKVkJFUmkweExqUUtNU0F3SUc5aWFqdzhMMVI1Y0dVdlEyRjBZV3h2Wnk5UVlXZGxjeUF5SURBZ1VqNCtaVzVrYjJKcUNqSWdNQ0J2DQpZbW84UEM5VWVYQmxMMUJoWjJWekwwdHBaSE5iWFM5RGIzVnVkQ0F3UGo1bGJtUnZZbW9LZEhKaGFXeGxjanc4TDFKdmIzUWdNU0F3DQpJRkkrUGdvbEpVVlBSZ289DQotLT1fbWluaW1haWxfbWl4ZWRfMGIxYzJkM2U0ZjVhNmI3Yy0tDQo
```

### 7.3 Gmail-web variant of the forward

To match Gmail web exactly (recommended, §1.5) insert `In-Reply-To: <CAF=abc123@mail.example.com>` after `Message-ID:` and send `{"threadId": "<original threadId>", "raw": …}`. This changes length/sha256/raw; regenerate with the script.

---

## 8. Test vectors

### 8.1 Reply-all recipient computation (self = `max.mustermann@newtelco.de`, alias = `m.mustermann@newtelco.de`)

| # | Original headers | Expected reply-all `To` | Expected `Cc` |
|---|---|---|---|
| 1 | From: `Alice <alice@example.com>`; To: `max.mustermann@newtelco.de` | `Alice <alice@example.com>` | — |
| 2 | From: `Alice <alice@example.com>`; To: `Max <max.mustermann@newtelco.de>, Bob <bob@example.com>`; Cc: `carol@partner.example` | `Alice <alice@example.com>, Bob <bob@example.com>` | `carol@partner.example` |
| 3 | From: `Alice <alice@example.com>`; Reply-To: `Support <support@example.com>`; To: `max.mustermann@newtelco.de, bob@example.com` | `Support <support@example.com>, bob@example.com` | — (Alice is **not** added — Reply-To replaces From) |
| 4 | From: `alice@example.com`; To: `MAX.MUSTERMANN@newtelco.de, Bob <bob@example.com>`; Cc: `M.Mustermann@NewTelco.de, dave@newtelco.de` | `alice@example.com, Bob <bob@example.com>` | `dave@newtelco.de` (both self spellings removed case-insensitively) |
| 5 | From: `Alice <alice@example.com>`; To: `bob@example.com`; Cc: `Alice <alice@example.com>, bob@example.com` | `Alice <alice@example.com>, bob@example.com` | — (duplicates of To removed; To wins over Cc) |
| 6 | From: `Alice <alice@example.com>`; Reply-To: `alice@example.com, list@example.com`; To: `max.mustermann@newtelco.de` | `alice@example.com, list@example.com` | — (multi-address Reply-To kept in order, first-seen display name — here none) |
| 7 | From: `"Müller, Alice" <alice@example.com>`; To: `max.mustermann@newtelco.de` | `"Müller, Alice" <alice@example.com>` (serialised as `=?UTF-8?B?TcO8bGxlciwgQWxpY2U=?= <alice@example.com>`) | — (comma inside quotes must not split) |
| 8 | From: `=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?= <alice@example.com>`; To: `max.mustermann@newtelco.de` | `Alice Müller <alice@example.com>` (decoded for display; re-encoded on output) | — |
| 9 | From: `Max Mustermann <max.mustermann@newtelco.de>` (own sent mail); To: `Alice <alice@example.com>, bob@example.com`; Cc: `carol@partner.example` | `Alice <alice@example.com>, bob@example.com` | `carol@partner.example` (self-reply: To = original To, Reply-To ignored) |
| 10 | From: `Max <max.mustermann@newtelco.de>`; Reply-To: `list@example.com`; To: `alice@example.com` | `alice@example.com` | — (self-reply ignores Reply-To — Google CLI `test_reply_all_to_own_message_ignores_reply_to`) |
| 11 | From: `Alice <alice@example.com>`; To: `Team: max.mustermann@newtelco.de, bob@example.com;` | `Alice <alice@example.com>, bob@example.com` | — (group flattened, group name dropped) |
| 12 | From: `alice@example.com (Alice)`; To: `undisclosed-recipients:;` | `Alice <alice@example.com>` | — (legacy comment used as name; empty group ⇒ nothing) |
| 13 | From: `Alice <alice@example.com>`; To: `max.mustermann@newtelco.de`; Cc: `max.mustermann@newtelco.de` | `Alice <alice@example.com>` | — |
| 14 | From: `Max <max.mustermann@newtelco.de>`; To: `max.mustermann@newtelco.de` (note to self) | `Max <max.mustermann@newtelco.de>` | — (last-resort rule: To may not be empty) |
| 15 | From: `Alice <alice@example.com>`; To: `bob@example.com,, ,carol@partner.example` (obs-addr-list) | `Alice <alice@example.com>, bob@example.com, carol@partner.example` | — (null members ignored, RFC 5322 §4.4) |
| 16 | From: `Alice <alice@example.com>`; To: `Bob <@relay.example:bob@example.com>` | `Alice <alice@example.com>, Bob <bob@example.com>` | — (obs-route dropped) |

### 8.2 Subject prefix

| Original Subject | Reply | Forward |
|---|---|---|
| `Angebot` | `Re: Angebot` | `Fwd: Angebot` |
| `Re: Angebot` | `Re: Angebot` | `Fwd: Re: Angebot` |
| `RE: Angebot` | `RE: Angebot` | `Fwd: RE: Angebot` |
| `Fwd: Angebot` | `Re: Fwd: Angebot` | `Fwd: Angebot` |
| `FW: Angebot` | `Re: FW: Angebot` | `Fwd: FW: Angebot` |
| `` (empty) | `Re: ` (Gmail web sends `Re: ` with trailing space; trimming to `Re:` also acceptable — UNVERIFIED) | `Fwd: ` |
| `=?UTF-8?B?QW5nZWJvdCBmw7xyIGRpZSBFcndlaXRlcnVuZw==?=` | decoded `Angebot für die Erweiterung` → `Re: Angebot für die Erweiterung` → header `=?UTF-8?B?UmU6IEFuZ2Vib3QgZsO8ciBkaWUgRXJ3ZWl0ZXJ1bmc=?=` | header `=?UTF-8?B?RndkOiBBbmdlYm90IGbDvHIgZGllIEVyd2VpdGVydW5n?=` |

### 8.3 Encoders/decoders (all verified against Python stdlib as an independent oracle)

Quoted-printable (input → exact output):
| Input (UTF-8 string, `\r\n` = CRLF) | Output |
|---|---|
| `Grüße` | `Gr=C3=BC=C3=9Fe` |
| `a=b` | `a=3Db` |
| `trailing space ` | `trailing space=20` |
| `tab\tend\t` | `tab\tend=09` |
| 80 × `x` | 75 × `x` + `=` + CRLF + 5 × `x` |
| `Viele Grüße\r\nMax` | `Viele Gr=C3=BC=C3=9Fe\r\nMax` |
| `-- ` | `--=20` |

RFC 2047 decoding (header value → display string):
| Input | Output |
|---|---|
| `=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?=` | `Alice Müller` |
| `=?utf-8?q?Gr=C3=BC=C3=9Fe_aus_K=C3=B6ln?=` | `Grüße aus Köln` |
| `=?UTF-8?Q?a?= =?UTF-8?Q?b?=` | `ab` |
| `=?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?=` | `Keld Jørn Simonsen` |
| `plain =?UTF-8?B?w6TDtsO8?= end` | `plain äöü end` |
| `=?UTF-8?B?4pyT?= ok` | `✓ ok` |
| `=?utf-8?B?SGk=?=` CRLF SPACE `=?utf-8?B?IHRoZXJl?=` | `Hi there` (folded, adjacent words joined, LWSP dropped) |
| `=?UTF-8?B?w6Q?=` (missing pad, common in the wild) | `ä` (tolerant decoder) |
| `=?X-UNKNOWN?Q?abc?=` | `=?X-UNKNOWN?Q?abc?=` (unchanged, RFC 2047 §6.2) |

base64 / base64url (bytes → std → url-nopad):
| bytes (hex) | base64 | base64url no pad |
|---|---|---|
| `` | `` | `` |
| `66` | `Zg==` | `Zg` |
| `666f` | `Zm8=` | `Zm8` |
| `666f6f` | `Zm9v` | `Zm9v` |
| `fbffbf` | `+/+/` | `-_-_` |
| `00112233445566778899aabbccddeeff` | `ABEiM0RVZneImaq7zN3u/w==` | `ABEiM0RVZneImaq7zN3u_w` |
Decoder must accept: padded and unpadded input; both alphabets; reject other characters (RFC 4648 §3.3).

RFC 2231 filename decoding:
| Content-Disposition value | filename |
|---|---|
| `attachment; filename="Angebot.pdf"` | `Angebot.pdf` |
| `attachment; filename*=utf-8''%C3%84ngebot%202026.pdf` | `Ängebot 2026.pdf` |
| `attachment; filename*=UTF-8'de'%C3%84ngebot.pdf` | `Ängebot.pdf` |
| `attachment; filename*0*=utf-8''%C3%84nge; filename*1*=bot; filename*2=".pdf"` | `Ängebot.pdf` |
| `attachment; filename="fallback.pdf"; filename*=utf-8''%C3%84ngebot.pdf` | `Ängebot.pdf` (extended wins) |
| `attachment; filename="=?UTF-8?B?w4RuZ2Vib3QucGRm?="` | `Ängebot.pdf` (tolerate illegal encoded-word) |

### 8.4 Address parsing (header → `[(name, addr)]`; identical to Python `email.utils.getaddresses` after RFC 2047 decoding)

| Input | Output |
|---|---|
| `"Müller, Alice" <alice@example.com>, bob@example.com` | `[("Müller, Alice","alice@example.com"), (nil,"bob@example.com")]` |
| `Alice (Sales) <alice@example.com>` | `[("Alice","alice@example.com")]` (comment dropped; Python keeps `Alice (Sales)` — either is acceptable, prefer dropping) |
| `=?UTF-8?B?QWxpY2UgTcO8bGxlcg==?= <alice@example.com>` | `[("Alice Müller","alice@example.com")]` |
| `Team: alice@example.com, bob@example.com;` | `[(nil,"alice@example.com"), (nil,"bob@example.com")]` |
| `alice@example.com (Alice)` | `[("Alice","alice@example.com")]` |
| `"Bob \"The Builder\"" <bob@example.com>` | `[("Bob \"The Builder\"","bob@example.com")]` |
| `Alice <Alice@Example.COM>` | `[("Alice","Alice@Example.COM")]` (case preserved; compare lowercased) |
| `<alice@example.com>` | `[(nil,"alice@example.com")]` |
| `alice@example.com` | `[(nil,"alice@example.com")]` |
| `Alice\r\n <alice@example.com>` (folded) | `[("Alice","alice@example.com")]` |

---

## 9. Swift implementation notes (no third-party code)

- Build the message as `[UInt8]`/`Data` from ASCII strings; join with `"\r\n"`; never let `String` line-ending normalisation touch it (Swift `String` keeps `\r\n` as one grapheme — index by `utf8` view).
- QP encoder operates on `Array(text.utf8)`; output ≤ 76 chars per line; encode `=` always, TAB/SPACE only when not last on the line; hex uppercase.
- Standard base64 with 76-col CRLF wrapping: `Data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])`. base64url for `raw`: `base64EncodedString()` (no options) then swap `+/` → `-_`, keep `=`.
- `Date` header: `DateFormatter` with `locale = Locale(identifier: "en_US_POSIX")`, `dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"`, `timeZone = .current`. Attribution date: `dateFormat = "EEE, MMM d, yyyy 'at' h:mm\u{202F}a"` in the same locale.
- `Message-ID`: `"<\(UUID().uuidString)@newtelco.de>"` (domain = the account's email domain from `getProfile`).
- Header folding: emit `To:`/`Cc:` as `name <addr>,` + CRLF + SPACE + next mailbox when the line would exceed 78; `References:` one msg-id per continuation line if needed.
- Foundation `Data(base64Encoded:)` requires padding and rejects `-`/`_` — hence the tolerant wrapper in §1.2 (verify with §8.3 vectors; Apple docs were unreachable in this session).
- Charset conversion: `CFStringConvertIANACharSetNameToEncoding`, `CFStringConvertEncodingToNSStringEncoding`, `String(data:encoding:)` (Apple docs unreachable — API names from memory, verify at compile time).
- Unit tests: pin §7.1/§7.2 byte-for-byte (compare SHA-256 and the `raw` strings), plus every table in §8 as parameterised XCTest cases.

## 10. Open items / UNVERIFIED

1. Whether Gmail's "Subject headers must match" ignores `Re:`/`Fwd:` prefixes — empirically yes (Gmail web does it), official wording not seen.
2. Whether Gmail's `send` accepts unpadded base64url — widely reported yes; minimail emits padded anyway.
3. The exact wording of the Gmail help page on signature images (`support.google.com/mail/answer/8395`) and of any Google doc stating that `data:` images are not rendered — blocked; the behaviour is consistently reported by many independent sources.
4. `attachmentId` stability across `messages.get` calls — community-reported unstable; always re-resolve.
5. Foundation base64 padding strictness and the CoreFoundation charset API names — not verified against Apple docs in this session; covered by unit tests.
6. RFC 3676 §4.3 as the citation for the `-- ` signature separator — text not available here.
7. Gmail web `Cc:` line position in the forwarded-message block when the original had a Cc — inferred from Google's CLI (after `To:`), not seen in a Gmail-web fixture.
