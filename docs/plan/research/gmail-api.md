# Gmail REST API v1 — research for minimail

Date: 2026-09-11. Scope: exactly what minimail stage 1 needs (list INBOX threads, fetch metadata/bodies, label changes, labels with colors/unread counts, incremental sync via `history.list`, send reply-all/forward with `threadId`, attachments, profile, signature, quotas, OAuth for iOS).

## Verification status (read this first)

Network egress in this research session blocked `developers.google.com`, `support.google.com`, `knowledge.workspace.google.com` and archive mirrors. Two official, machine-readable sources **were** reachable and are the primary basis of every endpoint/field/param statement below:

1. **Gmail API Discovery document** (authoritative schema Google generates the reference pages from): `https://www.googleapis.com/discovery/v1/apis/gmail/v1/rest` (identical bytes also served at `https://gmail.googleapis.com/$discovery/rest?version=v1`), `"revision": "20260907"`. All paths, HTTP methods, query params, defaults, enums, scopes and field descriptions marked **[DISC]** are quoted verbatim from it.
2. **Google OpenID configuration**: `https://accounts.google.com/.well-known/openid-configuration` — authoritative for the OAuth endpoints, marked **[OIDC]**.
3. Live probes against `gmail.googleapis.com` / `www.googleapis.com` (unauthenticated) marked **[PROBE]**.

Everything that only lives in prose guides (quota units, batch-size limits, history retention wording, restricted-scope policy, native-app OAuth doc, search-operator help) could only be checked via web-search result snippets that quote the official page. Those are marked **[SNIPPET: url]** — treat as very likely correct but not byte-verified. Anything I could not confirm at all is marked **UNVERIFIED**.

Reference URLs (official, blocked here but cite them in the plan):
- REST reference root: https://developers.google.com/workspace/gmail/api/reference/rest
- Sync guide: https://developers.google.com/workspace/gmail/api/guides/sync
- Batch guide: https://developers.google.com/workspace/gmail/api/guides/batch
- Quota: https://developers.google.com/workspace/gmail/api/reference/quota
- Scopes: https://developers.google.com/workspace/gmail/api/auth/scopes
- Sending: https://developers.google.com/workspace/gmail/api/guides/sending
- Threads: https://developers.google.com/workspace/gmail/api/guides/threads
- Search syntax: https://developers.google.com/workspace/gmail/api/guides/filtering and https://support.google.com/mail/answer/7190
- OAuth native apps: https://developers.google.com/identity/protocols/oauth2/native-app
- OAuth overview / refresh-token expiry: https://developers.google.com/identity/protocols/oauth2
- Restricted-scope verification: https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification
- Workspace considerations: https://developers.google.com/identity/protocols/oauth2/production-readiness/google-workspace
- Workspace admin app access control: https://support.google.com/a/answer/7281227

---

## Common facts

- Base URL **[DISC]**: `rootUrl = "https://gmail.googleapis.com/"`, `servicePath = ""`, `batchPath = "batch"`. All method paths below are relative to that, i.e. `https://gmail.googleapis.com/gmail/v1/users/{userId}/...`. (`https://www.googleapis.com/gmail/v1/...` also still resolves, but use the discovery `rootUrl`.)
- `userId` **[DISC]**: path param, `default = "me"`; "The user's email address. The special value `me` can be used to indicate the authenticated user."
- Auth: `Authorization: Bearer <access_token>` header. (Global query params `access_token` / `oauth_token` exist **[DISC]** but do not use them — they leak into logs.)
- Useful global query params **[DISC]**: `fields` ("Selector specifying which fields to include in a partial response."), `prettyPrint` (default `true`; set `false` to shave bytes), `alt` (`json` default; `media`), `quotaUser` (server-side only, ignore).
- Repeated params (`labelIds`, `metadataHeaders`, `historyTypes`) are sent by **repeating the key**: `?labelIds=INBOX&labelIds=UNREAD` **[DISC: `"repeated": true`]**.
- IDs: message/thread ids are hex strings (e.g. `"18f2c1a2b3c4d5e6"`); `historyId` is a **string** holding a `uint64` **[DISC: format uint64]**; `internalDate` is a **string** holding `int64` epoch **milliseconds** **[DISC]**. Parse both with `UInt64(...)`/`Int64(...)`, never as JSON numbers.
- All `MessagePartBody.data`, `Message.raw`, attachment `data` are **base64url** (RFC 4648 §5, `-` and `_`, usually without `=` padding) **[DISC: "base64url encoded string"]**. Decoder: replace `-`→`+`, `_`→`/`, pad to multiple of 4, `Data(base64Encoded:)`.
- Error envelope (observed **[PROBE]**):
  ```json
  {"error":{"code":401,"message":"Request is missing required authentication credential. ...","errors":[{"message":"Login Required.","domain":"global","reason":"required","location":"Authorization","locationType":"header"}],"status":"UNAUTHENTICATED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"CREDENTIALS_MISSING","domain":"googleapis.com","metadata":{"service":"gmail.googleapis.com","method":"..."}}]}}
  ```
  Keys to act on: `error.code` (HTTP status), `error.status` (`UNAUTHENTICATED`, `NOT_FOUND`, `RESOURCE_EXHAUSTED`, ...), `error.errors[0].reason` (e.g. `rateLimitExceeded`, `userRateLimitExceeded`, `notFound`, `failedPrecondition`) — the `reason` strings for 429/403 are **[SNIPPET: quota page]**, not byte-verified.

---

## Verified endpoint reference

### 1. `users.getProfile` — GET `gmail/v1/users/{userId}/profile` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.compose`, `gmail.metadata`, `gmail.modify`, `gmail.readonly`.

Request:
```http
GET https://gmail.googleapis.com/gmail/v1/users/me/profile
Authorization: Bearer ya29....
```
Response (`Profile` **[DISC]**):
```json
{
  "emailAddress": "user@newtelco.de",
  "messagesTotal": 12345,
  "threadsTotal": 6789,
  "historyId": "1234567"
}
```
Field descriptions **[DISC]**: `emailAddress` "The user's email address."; `historyId` (string, uint64) "The ID of the mailbox's current history record."; `messagesTotal`/`threadsTotal` int32 totals.

Use: (a) on login, to display the account and store `emailAddress` for reply-all self-dedupe; (b) cheapest way to obtain a **current** `historyId` right before/after a full sync (1 quota unit per **[SNIPPET: quota page]**).

### 2. `users.threads.list` — GET `gmail/v1/users/{userId}/threads` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.metadata`, `gmail.modify`, `gmail.readonly`.

Query params **[DISC]**:
| param | type | default | description (verbatim) |
|---|---|---|---|
| `labelIds` | string, repeated | — | "Only return threads with labels that match all of the specified label IDs." |
| `q` | string | — | "Only return threads matching the specified query. Supports the same query format as the Gmail search box. For example, `\"from:someuser@example.com rfc822msgid: is:unread\"`. Parameter cannot be used when accessing the api using the gmail.metadata scope." |
| `maxResults` | integer (uint32) | `100` | "Maximum number of threads to return. This field defaults to 100. The maximum allowed value for this field is 500." |
| `pageToken` | string | — | "Page token to retrieve a specific page of results in the list." |
| `includeSpamTrash` | boolean | `false` | "Include threads from `SPAM` and `TRASH` in the results." |

Request:
```http
GET https://gmail.googleapis.com/gmail/v1/users/me/threads?labelIds=INBOX&maxResults=50
```
Response (`ListThreadsResponse` **[DISC]**):
```json
{
  "threads": [
    {"id": "18f2c1a2b3c4d5e6", "snippet": "Hi, about the invoice...", "historyId": "1234501"},
    {"id": "18f2b0ffee112233", "snippet": "Meeting moved to 3pm", "historyId": "1234490"}
  ],
  "nextPageToken": "09876543210987654321",
  "resultSizeEstimate": 143
}
```
**[DISC]**: "List of threads. Note that each thread resource does not contain a list of `messages`. The list of `messages` for a given thread can be fetched using the `threads.get` method." `resultSizeEstimate` is an **estimate** — never show it as an exact count. `nextPageToken` absent ⇒ last page.

### 3. `users.threads.get` — GET `gmail/v1/users/{userId}/threads/{id}` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.addons.*`, `gmail.metadata`, `gmail.modify`, `gmail.readonly`.

Query params **[DISC]**: `format` (default `full`; enum **`full`** "Returns the full email message data with body content parsed in the `payload` field; the `raw` field is not used. Format cannot be used when accessing the api using the gmail.metadata scope.", **`metadata`** "Returns only email message IDs, labels, and email headers.", **`minimal`** "Returns only email message IDs and labels; does not return the email headers, body, or payload." — note **no `raw`** for threads), `metadataHeaders` (string, repeated: "When given and format is METADATA, only include headers specified.").

Request (list-row hydration, one call per thread returns every message's headers):
```http
GET https://gmail.googleapis.com/gmail/v1/users/me/threads/18f2c1a2b3c4d5e6?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&metadataHeaders=References&metadataHeaders=In-Reply-To&metadataHeaders=Reply-To
```
Response (`Thread` **[DISC]**: `id`, `snippet`, `historyId` "The ID of the last history record that modified this thread.", `messages[]` of `Message`):
```json
{
  "id": "18f2c1a2b3c4d5e6",
  "historyId": "1234501",
  "messages": [
    {
      "id": "18f2c1a2b3c4d5e6",
      "threadId": "18f2c1a2b3c4d5e6",
      "labelIds": ["UNREAD", "IMPORTANT", "CATEGORY_PERSONAL", "INBOX"],
      "snippet": "Hi, about the invoice...",
      "payload": {
        "partId": "",
        "mimeType": "multipart/alternative",
        "filename": "",
        "headers": [
          {"name": "From", "value": "Alice <alice@example.com>"},
          {"name": "To", "value": "user@newtelco.de"},
          {"name": "Subject", "value": "Invoice 42"},
          {"name": "Date", "value": "Thu, 10 Sep 2026 09:12:33 +0200"},
          {"name": "Message-ID", "value": "<CAF=abc123@mail.example.com>"}
        ],
        "body": {"size": 0}
      },
      "sizeEstimate": 8123,
      "historyId": "1234501",
      "internalDate": "1757488353000"
    }
  ]
}
```
With `format=metadata` the `payload` has `headers` (filtered to `metadataHeaders` if given) and `body.size`, but no `parts`/`data` (behaviour consistent with the enum description; exact shape of empty `body` is UNVERIFIED — treat `parts` and `body.data` as optional in the decoder).

### 4. `users.messages.list` — GET `gmail/v1/users/{userId}/messages` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.metadata`, `gmail.modify`, `gmail.readonly`.

Query params **[DISC]** (same names/defaults as threads.list): `labelIds` (repeated; "Only return messages with labels that match all of the specified label IDs. Messages in a thread might have labels that other messages in the same thread don't have."), `q` (same text as threads.list; "Parameter cannot be used when accessing the api using the gmail.metadata scope."), `maxResults` (default 100, max 500), `pageToken`, `includeSpamTrash` (default false).

Response (`ListMessagesResponse` **[DISC]**):
```json
{
  "messages": [
    {"id": "18f2c1a2b3c4d5e6", "threadId": "18f2c1a2b3c4d5e6"},
    {"id": "18f2c0c0c0c0c0c0", "threadId": "18f2b0ffee112233"}
  ],
  "nextPageToken": "12345",
  "resultSizeEstimate": 201
}
```
**[DISC]**: "Note that each message resource contains only an `id` and a `threadId`. Additional message details can be fetched using the messages.get method."

Use for minimail: the **Today** and **Unread** views (`q=` / `labelIds=UNREAD`) and the first full sync. `labelIds=INBOX&labelIds=UNREAD` is an AND.

### 5. `users.messages.get` — GET `gmail/v1/users/{userId}/messages/{id}` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.addons.*`, `gmail.metadata`, `gmail.modify`, `gmail.readonly`.

Query params **[DISC]**:
- `format` (default `full`): **`minimal`** "Returns only email message ID and labels; does not return the email headers, body, or payload."; **`full`** "Returns the full email message data with body content parsed in the `payload` field; the `raw` field is not used. Format cannot be used when accessing the api using the gmail.metadata scope."; **`raw`** "Returns the full email message data with body content in the `raw` field as a base64url encoded string; the `payload` field is not used. Format cannot be used when accessing the api using the gmail.metadata scope."; **`metadata`** "Returns only email message ID, labels, and email headers."
- `metadataHeaders` (string, repeated): "When given and format is `METADATA`, only include headers specified."
- `id` (path): "The ID of the message to retrieve. This ID is usually retrieved using `messages.list`."

Request (body on open):
```http
GET https://gmail.googleapis.com/gmail/v1/users/me/messages/18f2c1a2b3c4d5e6?format=full
```
Response (`Message` **[DISC]**, field descriptions verbatim):
- `id` "The immutable ID of the message."
- `threadId` "The ID of the thread the message belongs to. To add a message or draft to a thread, the following criteria must be met: 1. The requested `threadId` must be specified on the `Message` or `Draft.Message` you supply with your request. 2. The `References` and `In-Reply-To` headers must be set in compliance with the RFC 2822 standard. 3. The `Subject` headers must match."
- `labelIds[]` "List of IDs of labels applied to this message."
- `snippet` "A short part of the message text."
- `historyId` (string uint64) "The ID of the last history record that modified this message."
- `internalDate` (string int64) "The internal message creation timestamp (epoch ms), which determines ordering in the inbox. For normal SMTP-received email, this represents the time the message was originally accepted by Google, which is more reliable than the `Date` header."
- `payload` (`MessagePart`) "The parsed email structure in the message parts."
- `sizeEstimate` (int32) "Estimated size in bytes of the message."
- `raw` (string, byte) "The entire email message in an RFC 2822 formatted and base64url encoded string. Returned in `messages.get` and `drafts.get` responses when the `format=RAW` parameter is supplied."
- `classificationLabelValues[]` (Workspace-only classification labels; ignore).

`MessagePart` **[DISC]**: `partId` "The immutable ID of the message part."; `mimeType`; `filename` "The filename of the attachment. Only present if this message part represents an attachment."; `headers[]` of `MessagePartHeader {name, value}` ("For the top-level message part, representing the entire message payload, it will contain the standard RFC 2822 email headers such as `To`, `From`, and `Subject`."); `body` (`MessagePartBody`) "which may be empty for container MIME message parts."; `parts[]` "The child MIME message parts of this part. This only applies to container MIME message parts, for example `multipart/*`. For non- container MIME message part types, such as `text/plain`, this field is empty."

`MessagePartBody` **[DISC]**: `attachmentId` "When present, contains the ID of an external attachment that can be retrieved in a separate `messages.attachments.get` request. When not present, the entire content of the message part body is contained in the data field."; `size` (int32) "Number of bytes for the message part data (encoding notwithstanding)."; `data` (string, byte) "The body data of a MIME message part as a base64url encoded string. May be empty for MIME container types that have no message body or when the body data is sent as a separate attachment. An attachment ID is present if the body data is contained in a separate attachment."

Example `format=full` response (shape per schema; values illustrative):
```json
{
  "id": "18f2c1a2b3c4d5e6",
  "threadId": "18f2c1a2b3c4d5e6",
  "labelIds": ["UNREAD", "INBOX"],
  "snippet": "Hi, about the invoice...",
  "historyId": "1234501",
  "internalDate": "1757488353000",
  "sizeEstimate": 45210,
  "payload": {
    "partId": "",
    "mimeType": "multipart/mixed",
    "filename": "",
    "headers": [
      {"name": "From", "value": "Alice <alice@example.com>"},
      {"name": "To", "value": "user@newtelco.de"},
      {"name": "Cc", "value": "bob@example.com"},
      {"name": "Subject", "value": "Invoice 42"},
      {"name": "Date", "value": "Thu, 10 Sep 2026 09:12:33 +0200"},
      {"name": "Message-ID", "value": "<CAF=abc123@mail.example.com>"},
      {"name": "Content-Type", "value": "multipart/mixed; boundary=\"000000000000abcd\""}
    ],
    "body": {"size": 0},
    "parts": [
      {
        "partId": "0",
        "mimeType": "multipart/alternative",
        "filename": "",
        "headers": [{"name": "Content-Type", "value": "multipart/alternative; boundary=\"000000000000abce\""}],
        "body": {"size": 0},
        "parts": [
          {"partId": "0.0", "mimeType": "text/plain", "filename": "",
           "headers": [{"name": "Content-Type", "value": "text/plain; charset=\"UTF-8\""}, {"name": "Content-Transfer-Encoding", "value": "quoted-printable"}],
           "body": {"size": 412, "data": "SGksIGFib3V0IHRoZSBpbnZvaWNlLi4u"}},
          {"partId": "0.1", "mimeType": "text/html", "filename": "",
           "headers": [{"name": "Content-Type", "value": "text/html; charset=\"UTF-8\""}, {"name": "Content-Transfer-Encoding", "value": "quoted-printable"}],
           "body": {"size": 1533, "data": "PGRpdiBkaXI9Imx0ciI-SGksIGFib3V0IHRoZSBpbnZvaWNlLi4uPC9kaXY-"}}
        ]
      },
      {
        "partId": "1",
        "mimeType": "application/pdf",
        "filename": "invoice-42.pdf",
        "headers": [{"name": "Content-Type", "value": "application/pdf; name=\"invoice-42.pdf\""}, {"name": "Content-Disposition", "value": "attachment; filename=\"invoice-42.pdf\""}, {"name": "Content-Transfer-Encoding", "value": "base64"}],
        "body": {"attachmentId": "ANGjdJ8w...long...", "size": 38211}
      }
    ]
  }
}
```
Body-encoding facts for the parser:
- `data` is **already decoded** from the wire Content-Transfer-Encoding (quoted-printable/base64) by Gmail; after base64url-decoding you get the raw bytes of the part. Decode those bytes using the `charset=` in that part's `Content-Type` header (default UTF-8). (Behaviour widely relied upon; the description only says "body data ... as a base64url encoded string" — the CTE-already-removed part is **[SNIPPET/experience]**, verify on first real message.)
- `partId` strings look like `"0"`, `"0.1"`, `"1"` (illustrative; format not specified in the schema).
- Inline images in HTML come as parts with `Content-ID` headers and `attachmentId`; `cid:` URLs in the HTML must be rewritten to fetched attachment data (or left broken in stage 1 — remote images are off anyway).
- Simple non-multipart mails have `payload.mimeType = "text/plain"` or `"text/html"` and `payload.body.data` directly, `parts` absent — handle both shapes.
- Large text parts can also be delivered by `attachmentId` instead of inline `data` (the schema explicitly allows it: "or when the body data is sent as a separate attachment"). Handle a `text/html` part with `attachmentId` and no `data` by calling attachments.get.

### 6. `users.messages.attachments.get` — GET `gmail/v1/users/{userId}/messages/{messageId}/attachments/{id}` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.addons.current.message.action`, `gmail.addons.current.message.readonly`, `gmail.modify`, `gmail.readonly`.

Path params **[DISC]**: `messageId` "The ID of the message containing the attachment."; `id` "The ID of the attachment."

Request:
```http
GET https://gmail.googleapis.com/gmail/v1/users/me/messages/18f2c1a2b3c4d5e6/attachments/ANGjdJ8w...
```
Response (`MessagePartBody` **[DISC]**):
```json
{"size": 38211, "data": "JVBERi0xLjQKJ..."}
```
Decode `data` with base64url → bytes → write to a temp file with the `filename` from the `MessagePart` → QuickLook. `attachmentId` values are long and may change between fetches of the same message (UNVERIFIED but commonly reported) — always take the id from a fresh `messages.get`, do not persist it long-term as a stable key; persist `(messageId, partId, filename, mimeType, size)` and re-resolve `attachmentId` on tap.

### 7. `users.messages.modify` — POST `gmail/v1/users/{userId}/messages/{id}/modify` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.modify` (only these two).

Request body (`ModifyMessageRequest` **[DISC]**): `addLabelIds[]` "A list of IDs of labels to add to this message. You can add up to 100 labels with each update."; `removeLabelIds[]` "A list IDs of labels to remove from this message. You can remove up to 100 labels with each update." (plus Workspace `addClassificationLabels` / `removeClassificationLabelIds` — ignore).

```http
POST https://gmail.googleapis.com/gmail/v1/users/me/messages/18f2c1a2b3c4d5e6/modify
Content-Type: application/json

{"removeLabelIds": ["UNREAD"]}
```
Response: the updated `Message` (**[DISC]** `response: Message`; in practice returned in minimal shape — `id`, `threadId`, `labelIds` — shape beyond `labelIds` UNVERIFIED, decode leniently):
```json
{"id": "18f2c1a2b3c4d5e6", "threadId": "18f2c1a2b3c4d5e6", "labelIds": ["INBOX"]}
```
Mappings for minimail:
- mark read: `{"removeLabelIds":["UNREAD"]}`; mark unread: `{"addLabelIds":["UNREAD"]}`
- archive: `{"removeLabelIds":["INBOX"]}`; move back to inbox: `{"addLabelIds":["INBOX"]}`
- Both can be combined in one call: `{"addLabelIds":["UNREAD"],"removeLabelIds":["INBOX"]}`.

### 8. `users.messages.batchModify` — POST `gmail/v1/users/{userId}/messages/batchModify` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.modify`.

Request body (`BatchModifyMessagesRequest` **[DISC]**): `ids[]` "The IDs of the messages to modify. There is a limit of 1000 ids per request."; `addLabelIds[]` "A list of label IDs to add to messages."; `removeLabelIds[]` "A list of label IDs to remove from messages."

```http
POST https://gmail.googleapis.com/gmail/v1/users/me/messages/batchModify
Content-Type: application/json

{"ids": ["18f2c1a2b3c4d5e6", "18f2c0c0c0c0c0c0"], "removeLabelIds": ["INBOX"]}
```
Response **[DISC]**: `response: None` ⇒ **HTTP 204 No Content, empty body**. Do not try to decode JSON.

`batchModify` vs `modify` vs HTTP batch:
- `batchModify` = one HTTP request, one quota charge, same label delta applied to up to 1000 messages, **no per-message result** (all-or-nothing from the client's point of view; a bad id fails the whole call — UNVERIFIED which status).
- `modify` = one message, returns its new `labelIds` (useful to reconcile optimistic state).
- HTTP batch (§12) = N independent calls in one round-trip, N quota charges, per-call responses.
- Recommendation for the outbox: coalesce queued ops by identical `(add, remove)` delta and use `batchModify` when >1 message shares the delta; use `modify` for singles. Archiving a whole thread: use `threads.modify` (§9) — one call, applies to all messages in the thread.

### 9. `users.threads.modify` — POST `gmail/v1/users/{userId}/threads/{id}/modify` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.modify`. "Modifies the labels applied to the thread. This applies to all messages in the thread." Body (`ModifyThreadRequest`): `addLabelIds[]`, `removeLabelIds[]` (max 100 each). Response: `Thread` (with `messages[]` in minimal shape — UNVERIFIED depth).

```http
POST https://gmail.googleapis.com/gmail/v1/users/me/threads/18f2c1a2b3c4d5e6/modify
{"removeLabelIds": ["INBOX"]}
```
Archive-from-list should use this (the list is thread-based).

### 10. `users.labels.list` — GET `gmail/v1/users/{userId}/labels` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.labels`, `gmail.metadata`, `gmail.modify`, `gmail.readonly`.

Response (`ListLabelsResponse` **[DISC]**): "List of labels. Note that each label resource only contains an `id`, `name`, `messageListVisibility`, `labelListVisibility`, and `type`. The `labels.get` method can fetch additional label details."
```json
{
  "labels": [
    {"id": "INBOX", "name": "INBOX", "messageListVisibility": "hide", "labelListVisibility": "labelShow", "type": "system"},
    {"id": "UNREAD", "name": "UNREAD", "type": "system"},
    {"id": "SENT", "name": "SENT", "messageListVisibility": "hide", "labelListVisibility": "labelShow", "type": "system"},
    {"id": "CATEGORY_PERSONAL", "name": "CATEGORY_PERSONAL", "type": "system"},
    {"id": "Label_12", "name": "Customers/ACME", "messageListVisibility": "show", "labelListVisibility": "labelShow", "type": "user"}
  ]
}
```
**Counts and colors are NOT in the list response** — that is what the schema note says; in practice `color` for user labels is often present in list responses too, but `messagesUnread` etc. are not (UNVERIFIED for color; do not rely on it). Fetch `labels.get` per label you display (HTTP-batched, §12).

System label ids to know (string constants; `id == name` for system labels): `INBOX`, `UNREAD`, `STARRED`, `IMPORTANT`, `SENT`, `DRAFT`, `SPAM`, `TRASH`, `CHAT`, `CATEGORY_PERSONAL`, `CATEGORY_SOCIAL`, `CATEGORY_PROMOTIONS`, `CATEGORY_UPDATES`, `CATEGORY_FORUMS`. (Well-known; the discovery doc only says system labels are "internally created and cannot be added, modified, or deleted" and gives `INBOX`, `UNREAD`, `DRAFTS`, `SENT` as examples **[DISC]**.) User label ids look like `Label_12` / `Label_1234567890123456789`; nested labels are encoded in `name` with `/`.

### 11. `users.labels.get` — GET `gmail/v1/users/{userId}/labels/{id}` **[DISC]**

Scopes as labels.list. Response (`Label` **[DISC]**, verbatim descriptions):
- `id` "The immutable ID of the label."; `name` "The display name of the label."
- `type` enum: `system` "Labels created by Gmail."; `user` "Custom labels created by the user or application." Description: "...users can apply and remove the `INBOX` and `UNREAD` labels from messages and threads, but cannot apply or remove the `DRAFTS` or `SENT` labels from messages or threads."
- `messageListVisibility` enum `show` | `hide`; `labelListVisibility` enum `labelShow` | `labelShowIfUnread` | `labelHide` ("Show the label if there are any unread messages with that label.") — use these to mimic Gmail's sidebar.
- `messagesTotal` (int32) "The total number of messages with the label."; `messagesUnread` "The number of unread messages with the label."; `threadsTotal`; `threadsUnread` "The number of unread threads with the label."
- `color` (`LabelColor`) "The color to assign to the label. Color is only available for labels that have their `type` set to `user`." → `{ "textColor": "#RRGGBB", "backgroundColor": "#RRGGBB" }`, both restricted to a fixed palette of 100+ hex values (full list in the discovery doc; first entries: `#000000, #434343, #666666, #999999, #cccccc, #efefef, #f3f3f3, #ffffff, #fb4c2f, #ffad47, #fad165, #16a766, #43d692, #4a86e8, #a479e2, #f691b3, ...`). Parse as plain hex; do not validate against the palette on read.
```http
GET https://gmail.googleapis.com/gmail/v1/users/me/labels/Label_12
```
```json
{
  "id": "Label_12",
  "name": "Customers/ACME",
  "type": "user",
  "messageListVisibility": "show",
  "labelListVisibility": "labelShow",
  "messagesTotal": 120,
  "messagesUnread": 3,
  "threadsTotal": 44,
  "threadsUnread": 2,
  "color": {"textColor": "#ffffff", "backgroundColor": "#4a86e8"}
}
```
Inbox unread badge = `labels.get("INBOX").threadsUnread` (thread-based list) — system labels return counts but no `color`. Refresh counts after each delta sync (cheap: 1 unit each **[SNIPPET: quota page]**, batchable).

### 12. HTTP batch — POST `https://www.googleapis.com/batch/gmail/v1` **[PROBE + SNIPPET]**

Verified live **[PROBE]**: all three of `https://www.googleapis.com/batch/gmail/v1`, `https://gmail.googleapis.com/batch` (= discovery `rootUrl + batchPath`) and `https://gmail.googleapis.com/batch/gmail/v1` accept a `multipart/mixed` batch and return a `multipart/mixed` response with one `application/http` part per request, `Content-ID: <response-{your id}>`. Use the documented one: `https://www.googleapis.com/batch/gmail/v1` **[SNIPPET: batch guide]**.

Limits **[SNIPPET: https://developers.google.com/workspace/gmail/api/guides/batch]**: "You're limited to 100 calls in a single batch request. If you must make more calls than that, use multiple batch requests." Each inner call is charged its own quota (a batch of n counts as n). Community/quota guidance says keep batches ≤ 50 to avoid per-user rate-limit errors inside the batch **[SNIPPET: unipile/nylas, not official — UNVERIFIED as official text]**. PLAN.md's "≤50 per request" is consistent.

Request (exact wire format, verified by probe):
```http
POST https://www.googleapis.com/batch/gmail/v1 HTTP/1.1
Authorization: Bearer ya29....
Content-Type: multipart/mixed; boundary=batch_minimail_1

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
Rules: CRLF line endings; inner request line is `METHOD path[?query]` with a **path relative to the host** (`/gmail/v1/...`); a blank line after the part headers, then the inner request; inner bodies need their own `Content-Type`. The outer `Authorization` header applies to every part. Do **not** nest batches.

Response (observed **[PROBE]**):
```http
HTTP/2 200
content-type: multipart/mixed; boundary=batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN

--batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN
Content-Type: application/http
Content-ID: <response-m1>

HTTP/1.1 200 OK
Content-Type: application/json; charset=UTF-8

{ "id": "18f2c1a2b3c4d5e6", ... }
--batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN
Content-Type: application/http
Content-ID: <response-m2>

HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="https://accounts.google.com/"
Content-Type: application/json; charset=UTF-8

{ "error": { "code": 401, ... } }
--batch_sIZwsd8Ehv3bGH31LWHkyZFnDQFJXEbN--
```
Parsing: the outer response is 200 even when every part failed — read each part's inner status line. Match by `Content-ID` (`<response-` + your id + `>`), not by order. A 429 inside a part means retry only that part with backoff.

Swift note: `URLSession` cannot build multipart for you — write a small `BatchRequest` builder/parser (boundary split on `"\r\n--" + boundary`), unit-test it against the sample above.

### 13. `users.history.list` — GET `gmail/v1/users/{userId}/history` **[DISC]**

Scopes: `https://mail.google.com/`, `gmail.metadata`, `gmail.modify`, `gmail.readonly`. "Lists the history of all changes to the given mailbox. History results are returned in chronological order (increasing `historyId`)."

Query params **[DISC]**:
| param | type | default | description (verbatim) |
|---|---|---|---|
| `startHistoryId` | string (uint64) | — | "Required. Returns history records after the specified `startHistoryId`. The supplied `startHistoryId` should be obtained from the `historyId` of a message, thread, or previous `list` response. History IDs increase chronologically but are not contiguous with random gaps in between valid IDs. Supplying an invalid or out of date `startHistoryId` typically returns an `HTTP 404` error code. A `historyId` is typically valid for at least a week, but in some rare circumstances may be valid for only a few hours. If you receive an `HTTP 404` error response, your application should perform a full sync. If you receive no `nextPageToken` in the response, there are no updates to retrieve and you can store the returned `historyId` for a future request." |
| `labelId` | string | — | "Only return messages with a label matching the ID." |
| `historyTypes` | string, repeated | — | enum `messageAdded`, `messageDeleted`, `labelAdded`, `labelRemoved` — "History types to be returned by the function" |
| `maxResults` | integer (uint32) | `100` | "Maximum number of history records to return. This field defaults to 100. The maximum allowed value for this field is 500." |
| `pageToken` | string | — | "Page token to retrieve a specific page of results in the list." |

Request (minimail delta sync; do **not** pass `labelId=INBOX` — you need `labelsRemoved` for messages leaving INBOX and read/unread changes on any label):
```http
GET https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=1234501&maxResults=500&historyTypes=messageAdded&historyTypes=messageDeleted&historyTypes=labelAdded&historyTypes=labelRemoved
```
Response (`ListHistoryResponse` **[DISC]**: `history[]`, `nextPageToken`, `historyId` "The ID of the mailbox's current history record."; "Any `messages` contained in the response will typically only have `id` and `threadId` fields populated."):
```json
{
  "history": [
    {
      "id": "1234510",
      "messages": [{"id": "18f2d000aaaa0001", "threadId": "18f2d000aaaa0001"}],
      "messagesAdded": [
        {"message": {"id": "18f2d000aaaa0001", "threadId": "18f2d000aaaa0001", "labelIds": ["UNREAD", "INBOX"]}}
      ]
    },
    {
      "id": "1234512",
      "messages": [{"id": "18f2c1a2b3c4d5e6", "threadId": "18f2c1a2b3c4d5e6"}],
      "labelsRemoved": [
        {"message": {"id": "18f2c1a2b3c4d5e6", "threadId": "18f2c1a2b3c4d5e6", "labelIds": ["INBOX"]}, "labelIds": ["UNREAD"]}
      ]
    },
    {
      "id": "1234515",
      "messages": [{"id": "18f2b0ffee112233", "threadId": "18f2b0ffee112233"}],
      "labelsAdded": [
        {"message": {"id": "18f2b0ffee112233", "threadId": "18f2b0ffee112233", "labelIds": ["INBOX", "Label_12"]}, "labelIds": ["Label_12"]}
      ]
    },
    {
      "id": "1234520",
      "messages": [{"id": "18f2a00000000001", "threadId": "18f2a00000000001"}],
      "messagesDeleted": [
        {"message": {"id": "18f2a00000000001", "threadId": "18f2a00000000001"}}
      ]
    }
  ],
  "nextPageToken": "...",
  "historyId": "1234530"
}
```
`History` **[DISC]**: `id` "The mailbox sequence ID."; `messages[]` "List of messages changed in this history record. The fields for specific change types, such as `messagesAdded` may duplicate messages in this field. We recommend using the specific change-type fields instead of this."; `messagesAdded[]` `{message}` "Messages added to the mailbox in this history record."; `messagesDeleted[]` `{message}` "Messages deleted (not Trashed) from the mailbox in this history record."; `labelsAdded[]` `{message, labelIds[]}` "Label IDs added to the message."; `labelsRemoved[]` `{message, labelIds[]}` "Label IDs removed from the message."

Whether `message.labelIds` (post-change label set) is populated inside `labelsAdded`/`labelsRemoved`/`messagesAdded` is stated by the sync guide **[SNIPPET: sync guide: "returns all current Message.labelIds as part of the response in messagesAdded, messagesDeleted, labelsAdded, and labelsRemoved"]** — rely on it but fall back to `messages.get?format=minimal` if absent.

**historyId semantics (for the SyncEngine):**
1. Obtain the baseline `historyId` **from the same snapshot** you stored: use `getProfile().historyId` taken *before* the full listing (safe: replaying overlapping records is idempotent), or the max `historyId` over fetched messages/threads.
2. `startHistoryId` is exclusive ("after the specified"). Pass the stored value unchanged; ids are non-contiguous, never arithmetic on them.
3. Page with `pageToken` until absent; then persist the top-level `historyId` from the **last** page (or from the first page if there was no `history` at all — the field is present even when `history` is empty: **[SNIPPET/experience: UNVERIFIED]**; if missing, keep the old id).
4. Apply per record, in order: `messagesAdded` → insert (fetch via batched `messages.get?format=metadata`; a **404 on get means it was already deleted** — drop it silently **[SNIPPET: sync guide]**); `messagesDeleted` → delete row; `labelsAdded`/`labelsRemoved` → apply delta to `label_ids`, recompute `is_unread`/`in_inbox`. Trash/spam appear as `labelsAdded: ["TRASH"]`, not `messagesDeleted`.
5. **404 (`error.status: "NOT_FOUND"`) on history.list ⇒ stored id expired ⇒ full resync** (drop `history_id`, re-run first-launch sync). Also treat **400** with `failedPrecondition`/invalid id the same way (UNVERIFIED which code Google uses for a malformed id).
6. Retention **[DISC + SNIPPET]**: "typically valid for at least a week, but in some rare circumstances may be valid for only a few hours" — so a BG refresh after a week offline must expect a 404 path; make full resync cheap (INBOX ~50 threads).
7. Your own `modify` calls also produce history records; applying them again is harmless (idempotent set ops) — but the record may arrive *before* the optimistic outbox op is acknowledged; apply history deltas over the DB and let the outbox re-apply its pending delta on top.

### 14. `users.messages.send` — POST `gmail/v1/users/{userId}/messages/send` **[DISC]**

Scopes **[DISC]**: `https://mail.google.com/`, `gmail.addons.current.action.compose`, `gmail.compose`, **`gmail.modify`**, `gmail.send`. ⇒ **`gmail.modify` alone is sufficient to send.** (Confirms PLAN.md single-scope choice.)

Two transports **[DISC]**:
- Metadata (JSON) URI: `POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send`, body = `Message` JSON with `raw` (+ `threadId`). Practical cap for JSON bodies is Google's general request size; the send docs put the message limit at 35 MB total — that figure is **[SNIPPET/experience: UNVERIFIED]**.
- Media upload URI: `POST https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=media` with `Content-Type: message/rfc822` and the **raw (not base64) RFC 5322 bytes** as body; `mediaUpload.accept = ["message/*"]`, `maxSize = "36700160"` (= 35 MiB) **[DISC]**; resumable path `/resumable/upload/gmail/v1/users/{userId}/messages/send`. Use this for forwards with big attachments (>~5 MB) to avoid the 33 % base64 inflation inside JSON; for stage 1 the JSON `raw` path is fine.

Request (reply-all in-thread):
```http
POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send
Content-Type: application/json

{
  "threadId": "18f2c1a2b3c4d5e6",
  "raw": "RnJvbTogdXNlckBuZXd0ZWxjby5kZQpUbzogYWxpY2VAZXhhbXBsZS5jb20K..."
}
```
`raw` = base64url( RFC 5322 message ). The MIME the builder must emit for a reply-all:
```
From: Your Name <user@newtelco.de>
To: Alice <alice@example.com>
Cc: bob@example.com
Subject: Re: Invoice 42
In-Reply-To: <CAF=abc123@mail.example.com>
References: <older-id@example.com> <CAF=abc123@mail.example.com>
Date: Fri, 11 Sep 2026 10:00:00 +0200
Message-ID: <7C1E3F2A-...@newtelco.de>
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="mm-alt-1"

--mm-alt-1
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

...plain text + quoted original...
--mm-alt-1
Content-Type: text/html; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

<div style="font-family:...;color:...">...</div><br>--signature html--<blockquote>...</blockquote>
--mm-alt-1--
```
Threading rules (verbatim, `Message.threadId` **[DISC]**): "1. The requested `threadId` must be specified ... 2. The `References` and `In-Reply-To` headers must be set in compliance with the RFC 2822 standard. 3. The `Subject` headers must match." ⇒ `In-Reply-To` = original `Message-ID`; `References` = original `References` + original `Message-ID`; Subject = original subject with `Re: ` prefix (Gmail's "match" ignores `Re:`/`Fwd:` prefixes in practice — UNVERIFIED as documented text; keep the original subject text unchanged after the prefix). Use `\r\n` line endings; fold nothing longer than 998 chars; encode non-ASCII header values (RFC 2047) — Gmail is lenient but do it.

Forward: new `Message-ID`, no `In-Reply-To`; optionally omit `threadId` (Gmail keeps forwards in the original thread only if `threadId` + `References` are set — behaviour choice; PLAN.md wants `threadId` set). Attachment passthrough: fetch each `attachmentId`, re-embed as `multipart/mixed` parts with `Content-Transfer-Encoding: base64` (standard 76-col base64, **not** base64url) and `Content-Disposition: attachment; filename="..."`.

Response: the sent `Message` **[DISC]** (minimal shape, e.g. `{"id":"18f2e...","threadId":"18f2c1a2b3c4d5e6","labelIds":["SENT"]}`). `Bcc`/`Cc` recipients are honoured from headers ("Sends the specified message to the recipients in the `To`, `Cc`, and `Bcc` headers." **[DISC]**). Gmail rewrites `From` to the account's primary/send-as address if it does not match. Gmail also assigns its own `Message-ID` if you omit one — but then you cannot know it for the local cache; always set one.

Idempotency: **there is no idempotency key**. A timed-out send may have succeeded. Outbox rule: before retrying a send whose request was actually transmitted, run `messages.list?q=rfc822msgid:<your Message-ID>` (the `q` doc explicitly lists `rfc822msgid:` **[DISC]**) and skip if found.

### 15. `users.settings.sendAs.list` / `.get` **[DISC]**

- `GET gmail/v1/users/{userId}/settings/sendAs` → `{"sendAs": [SendAs...]}`; scopes: `https://mail.google.com/`, **`gmail.modify`**, `gmail.readonly`, `gmail.settings.basic` ⇒ readable with `gmail.modify`.
- `GET gmail/v1/users/{userId}/settings/sendAs/{sendAsEmail}` → `SendAs`. "Fails with an HTTP 404 error if the specified address is not a member of the collection."

`SendAs` fields **[DISC]**: `sendAsEmail`, `displayName` ("A name that appears in the "From:" header..."), `replyToAddress`, `signature` — **"An optional HTML signature that is included in messages composed with this alias in the Gmail web UI. This signature is added to new emails only."** —, `isPrimary`, `isDefault`, `treatAsAlias`, `verificationStatus` (`accepted`|`pending`), `smtpMsa`.
```json
{"sendAs":[{"sendAsEmail":"user@newtelco.de","displayName":"Your Name","signature":"<div dir=\"ltr\">Your Name<br>newtelco</div>","isPrimary":true,"isDefault":true}]}
```
Is it useful? **Yes, as a one-tap "Import Gmail signature" in Settings and as the source of `displayName` for the `From:` header** — the API does not append the signature for you (it is a web-UI feature: "included in messages composed ... in the Gmail web UI"), so minimail must embed it in the HTML body itself, which PLAN.md already does. Signature HTML from Gmail may reference hosted images (`https://ci3.googleusercontent.com/...` proxied URLs or `cid:`); keep as-is (remote image), do not inline. Writing the signature back requires `gmail.settings.basic` (sensitive scope) — out of scope; keep the local copy authoritative.

---

## Quotas and rate limits **[SNIPPET — official page blocked]**

Official page: https://developers.google.com/workspace/gmail/api/reference/quota. Search snippets quoting it in 2026 say:
- Limits changed **May 1, 2026** for new projects: **1,200,000 quota units/min per project**, **6,000 quota units/min per user per project** (one snippet says 15,000/user/min — conflicting), plus an 80,000,000 units/day per-project "billing threshold" announced for later 2026. Projects that used the API Nov 2025–Apr 2026 keep the previous limits (historically **250 units/user/second**, 1,000,000,000 units/day). Since minimail's GCP project will be **new**, plan for **6,000 units/user/min ≈ 100 units/s**.
- Per-method units, as quoted by 2026 snippets: `messages.list` 5, `messages.get` **20** (older docs: 5), `threads.get` **40** (older: 10), `messages.send` 100, `history.list` 2, `labels.list` 1, `labels.get` 1, `getProfile` 1. Not quoted in any snippet, historically: `messages.modify` 5, `messages.batchModify` 50, `messages.attachments.get` 5, `threads.list` 10, `threads.modify` 10, `settings.sendAs.get/list` 1. **Treat the whole table as UNVERIFIED until the agent fetches the page; design for the higher numbers.**
- Budget check with the pessimistic table: first sync 50 threads via `threads.get?format=metadata` = 50×40 = 2,000 units in one batch — under 6,000/min but a second batch in the same minute could 429. Prefer `messages.list?labelIds=INBOX&maxResults=100` (5) + batched `messages.get?format=metadata` (100×20 = 2,000). Delta sync = 2 + 20×n. Sending = 100. Label counts 15×1.
- Exceeding limits returns **HTTP 429** (`rateLimitExceeded` / `userRateLimitExceeded`) or 403 (`dailyLimitExceeded`) **[SNIPPET]**; retry with exponential backoff + jitter (start 1 s, cap 32 s, max 5 tries); honour `Retry-After` if present. Also seen: **HTTP 429 with reason `concurrent` / "Too many concurrent requests for user"** — snippets mention a **max of 50 concurrent in-flight requests per mailbox** (UNVERIFIED). Keep minimail to ≤ 4 concurrent HTTP requests plus batching.

## OAuth scopes and Workspace policy

Scope needed by every stage-1 call (all **[DISC]** scope lists above): **`https://www.googleapis.com/auth/gmail.modify`** covers `getProfile`, `messages.list/get/modify/batchModify/send`, `attachments.get`, `threads.list/get/modify`, `labels.list/get`, `history.list`, `settings.sendAs.list/get`. Nothing in stage 1 needs `https://mail.google.com/` (only permanent delete does). `gmail.send` is **not** needed in addition — `send` lists `gmail.modify` explicitly.

Classification **[SNIPPET: scopes page + support.google.com/cloud/answer/13464325]**: `gmail.modify`, `gmail.readonly`, `gmail.compose`, `gmail.insert`, `gmail.metadata`, `gmail.settings.basic`, `gmail.settings.sharing`, `https://mail.google.com/` are **Restricted**; `gmail.send` is **Sensitive**; `gmail.labels` is **Non-sensitive**.

What "restricted" means for an **Internal** OAuth app in the newtelco.de org **[SNIPPET: developers.google.com/workspace/guides/configure-oauth-consent, .../production-readiness/restricted-scope-verification, support.google.com/cloud/answer/13464321]**:
- "For apps used only internally by your Google Workspace organization, scopes aren't listed on the consent screen and use of restricted or sensitive scopes doesn't require further review by Google." Exceptions to verification **and** to the annual CASA security assessment include "apps that are configured to work only with internal Google accounts within your organization". ⇒ **No verification, no security assessment, no 100-test-user cap, no 7-day refresh-token expiry** (the 7-day expiry applies to *External* apps in *Testing* status) — as long as User type = **Internal** (requires the GCP project to belong to the newtelco.de Workspace organization).
- Admin side **[SNIPPET: support.google.com/a/answer/7281227, 9352843]**: Admin console → Security → Access and data control → **API controls** → *Manage Third-Party App Access*. Apps get `Trusted` / `Limited` / `Blocked`. `Limited` = "access to scopes only from Google services which are not restricted" — Gmail scopes **are** restricted, so a `Limited` default would block minimail. Either the admin marks the client ID **Trusted**, or enables **"Trust internal, domain-owned apps"** under Internal App Settings ("allows API access for all internal apps"). Error seen when blocked: `Error 400: admin_policy_enforced` **[SNIPPET]**. PLAN.md's checklist item covers this; make it explicit: *either* per-app Trusted *or* the internal-apps checkbox.

## OAuth 2.0 for iOS (AppAuth-iOS)

Endpoints **[OIDC — verified]**:
- `authorization_endpoint`: `https://accounts.google.com/o/oauth2/v2/auth`
- `token_endpoint`: `https://oauth2.googleapis.com/token`
- `revocation_endpoint`: `https://oauth2.googleapis.com/revoke`
- `issuer`: `https://accounts.google.com` (AppAuth `discoverConfiguration(forIssuer:)` works; or hard-code the two endpoints — avoids a network round-trip at launch)
- `code_challenge_methods_supported`: `["plain","S256"]` → use **S256**; `grant_types_supported` includes `authorization_code`, `refresh_token`; `response_modes_supported`: `query`, `fragment`, `form_post`; `token_endpoint_auth_methods_supported`: `client_secret_post`, `client_secret_basic` (irrelevant — iOS clients have no secret).

Client type and redirect **[SNIPPET: native-app doc; VERIFIED via AppAuth-iOS Examples/README-Google.md (raw GitHub)]**:
- Create an OAuth client of type **iOS** with the app's Bundle ID (`de.newtelco.minimail`). Client ID format: `IDENTIFIER.apps.googleusercontent.com`. "Google's iOS clients do not have a secret" — `clientSecret: nil` in AppAuth.
- Redirect URI = reversed client ID as custom scheme + path: `com.googleusercontent.apps.IDENTIFIER:/oauth2redirect/google` (AppAuth README) / `com.googleusercontent.apps.IDENTIFIER:/oauth2redirect` (Google doc); **single slash after the colon**. The Cloud console shows the scheme as "iOS URL scheme". Register the scheme in `Info.plist` → `CFBundleURLTypes[0].CFBundleURLSchemes = ["com.googleusercontent.apps.IDENTIFIER"]`. (Headless build: put it in the `Info.plist` / `INFOPLIST_KEY_CFBundleURLTypes` via project.yml or the pbxproj — no Xcode GUI needed.)
- Universal Links / `https` redirects are optional; custom scheme is the documented default for iOS.

Authorization request (AppAuth `OIDAuthorizationRequest` builds this; params per native-app doc **[SNIPPET]** and OIDC):
```
https://accounts.google.com/o/oauth2/v2/auth?
  client_id=IDENTIFIER.apps.googleusercontent.com
  &redirect_uri=com.googleusercontent.apps.IDENTIFIER:/oauth2redirect
  &response_type=code
  &scope=https://www.googleapis.com/auth/gmail.modify
  &code_challenge=<base64url(SHA256(code_verifier))>
  &code_challenge_method=S256
  &state=<random>
  &login_hint=user@newtelco.de        (optional; skips account picker)
  &hd=newtelco.de                     (optional; UNVERIFIED for native flow, harmless)
```
PKCE **[SNIPPET: RFC 7636 / Google doc]**: `code_verifier` 43–128 chars from `[A-Za-z0-9-._~]`; AppAuth generates it automatically ("everything will be protected with PKCE" — AppAuth README **[verified]**). `access_type=offline` / `prompt=consent` are **web-server-flow** params; native (installed) clients always receive a refresh token on the first authorization — UNVERIFIED as documented text but consistent with AppAuth behaviour; if `refresh_token` is missing, add `prompt=consent`.

Token exchange (AppAuth does it; `OIDAuthState.authState(byPresenting:...)`):
```http
POST https://oauth2.googleapis.com/token
Content-Type: application/x-www-form-urlencoded

code=4/0A...&client_id=IDENTIFIER.apps.googleusercontent.com&code_verifier=...&grant_type=authorization_code&redirect_uri=com.googleusercontent.apps.IDENTIFIER:/oauth2redirect
```
```json
{"access_token":"ya29.a0...","expires_in":3599,"refresh_token":"1//0g...","scope":"https://www.googleapis.com/auth/gmail.modify","token_type":"Bearer"}
```
Refresh: `POST https://oauth2.googleapis.com/token` with `client_id`, `refresh_token`, `grant_type=refresh_token` → `{access_token, expires_in, scope, token_type}` (no new refresh token). Access tokens live ~1 hour (`expires_in` 3599 **[SNIPPET/experience]**). Use `OIDAuthState.performAction(freshTokens:)` before every API call; persist the whole `OIDAuthState` (NSSecureCoding) in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so BG refresh works).

Revocation **[OIDC endpoint verified; params SNIPPET: oauth2 web-server doc]**: `POST https://oauth2.googleapis.com/revoke` with `Content-Type: application/x-www-form-urlencoded`, body `token=<access or refresh token>`; 200 on success, 400 on invalid token; revoking an access token also revokes its refresh token. Sign-out = revoke refresh token + wipe Keychain + wipe SQLite.

Refresh-token lifetime for a Workspace user **[SNIPPET: developers.google.com/identity/protocols/oauth2 "Refresh token expiration"; support.google.com/a/answer/6328616]**:
- Not expiring by age for Internal apps (the 7-day expiry only hits External apps in *Testing*).
- Revoked if: user revokes access; **unused for six months**; **user changes their password and the app has Gmail scopes** (explicitly documented — expect forced re-login after password rotation); more than **50 refresh tokens** issued to the same client for the same account (oldest die — reinstalls count); admin revokes in Admin console; Workspace *Google Cloud session control* can invalidate tokens but only for Cloud scopes (Gmail scopes not affected per snippet).
- Failure surface: token endpoint returns `400 {"error":"invalid_grant"}` → clear state, show "Sign in again". Do not loop.

## Searching for "today" (`q=`) and timezone caveats

Documented syntax **[DISC: "Supports the same query format as the Gmail search box"; SNIPPET: filtering guide, support.google.com/mail/answer/7190]**: `after:YYYY/MM/DD`, `before:YYYY/MM/DD` (e.g. `after:2014/01/01 before:2014/02/01`), `newer_than:1d`/`older_than:2d`, `is:unread`, `label:X`, `in:inbox`, `rfc822msgid:`.
- `after:`/`before:` with **epoch seconds** (`after:1757541600`) works and is described as supported in Google's developer docs by secondary sources (labnol, emailanalytics) — **UNVERIFIED in official text**; it is the only way to get a timezone-exact boundary. Test once on the real account during M2; fall back to the date form.
- Date form semantics: `after:2026/09/11` means messages *on or after* that date; the date is interpreted in the **user's Gmail setting timezone**, not the device's (UNVERIFIED wording; commonly reported). `newer_than:1d` is a rolling 24 h, not "today".
- **Recommendation for minimail's Today view**: do not query the API at all. Compute locally from the SQLite cache: `internalDate >= startOfDay(in: TimeZone.current)` (ms epoch). The inbox cache already contains everything recent; the API is only needed if the user has > N inbox messages older than the cache window, which the local-first design excludes. If a server query is ever needed: `q=in:inbox after:<epochSecondsOfLocalMidnight>` and, on failure/empty, `after:YYYY/MM/DD` computed in local time.
- `q` cannot be combined with the `gmail.metadata` scope **[DISC]** — irrelevant with `gmail.modify`.
- `labelIds` filters are ANDed and are cheaper/more precise than `q=label:` (no query parsing, exact ids).

---

## Gotchas

1. **Scope**: `gmail.modify` covers everything in stage 1 including `send` and reading `sendAs` **[DISC]**. Do not add `gmail.send`/`gmail.readonly` — extra scopes only add consent noise.
2. **Restricted scope + Internal app**: no Google review, but the **Workspace admin must allow the client** (Trusted, or "Trust internal, domain-owned apps"); otherwise `admin_policy_enforced`. Put this in the setup checklist before the first login attempt.
3. **`historyId`/`internalDate` are strings** in JSON (`uint64`/`int64`) — decode as `String` then convert; never `Int` in Codable directly (JSONDecoder will fail on quoted numbers).
4. **404 from history.list = full resync**, not an error to surface. Expect it after > 7 days offline, occasionally after hours.
5. **`messagesAdded` can reference already-deleted messages**; `messages.get` 404 during delta must be swallowed.
6. **Delete vs trash**: `messagesDeleted` is only permanent deletion; trashing shows up as `labelsAdded: ["TRASH"]`. Treat `TRASH`/`SPAM` in `labelIds` as "hide from all views".
7. **`labels.list` has no counts (and officially no color)** — batch `labels.get` for the labels you show. Counts are per label; `INBOX.threadsUnread` is the badge.
8. **Thread-level vs message-level labels**: `UNREAD` is per message. A thread is unread if any message has `UNREAD`. Archive = remove `INBOX` from **all** messages (`threads.modify`), otherwise the thread re-appears in the inbox via the other messages. Marking a thread read = `threads.modify removeLabelIds:["UNREAD"]`.
9. **Batch endpoint returns 200 even when parts fail**; parse inner status lines; 100 calls max per batch; each part is billed. Match by `Content-ID`.
10. **`batchModify` returns 204 empty body**, no per-id results; 1000 ids max.
11. **Quota table changed in 2026** for new projects (`messages.get` likely 20, `threads.get` 40, ~6,000 units/user/min). Prefer `messages.list` + batched `messages.get?format=metadata&metadataHeaders=...` over `threads.get` for hydration; verify the live page before tuning batch sizes.
12. **`format=metadata` + `metadataHeaders`** returns only the named headers — list every header the app needs (`From, To, Cc, Reply-To, Subject, Date, Message-ID, References, In-Reply-To, List-Unsubscribe`). Missing one means a second `messages.get` later.
13. **Body `data` is base64url and already CTE-decoded**; charset comes from the part's `Content-Type`. Text parts may arrive by `attachmentId` when large.
14. **Attachment ids are not stable identifiers**; re-read them from a fresh `messages.get` before `attachments.get`.
15. **No idempotency on `send`**: set your own `Message-ID`, and before retrying a possibly-sent message check `messages.list?q=rfc822msgid:<id>`.
16. **Threading on send** needs all three: `threadId` + `In-Reply-To`/`References` + matching `Subject` **[DISC]**. A wrong `References` chain silently creates a new thread.
17. **Signature from `sendAs.signature` is web-UI-only**; the API never appends it — minimail must embed it in the outgoing HTML (already planned). Reading it needs no extra scope; writing it would (`gmail.settings.basic`).
18. **Refresh tokens die on password change** (Gmail-scope apps) and after 6 months unused; handle `invalid_grant` with a clean re-login, never a retry loop. iOS client has **no client secret**.
19. **Redirect scheme** is the reversed client ID with a **single slash** path (`com.googleusercontent.apps.IDENTIFIER:/oauth2redirect`); it must be in `CFBundleURLSchemes` or the callback never reaches the app.
20. **"Today" should be computed locally** from `internalDate` in the device timezone; server-side `after:` date strings are evaluated in the account's Gmail timezone, and epoch-second `after:` is undocumented officially.
21. **`resultSizeEstimate` is an estimate**; never display it as a count. Use label counts from `labels.get`.
22. **Repeated query params** must be repeated keys (`labelIds=A&labelIds=B`), not comma-joined.
23. **`prettyPrint=false` + `fields=`** reduce payload size noticeably on `threads.get`/`messages.get` — e.g. `fields=id,threadId,labelIds,snippet,historyId,internalDate,payload/headers` for metadata hydration.
24. **Concurrency**: snippets mention a per-mailbox concurrent-request cap (~50). Keep a small semaphore (≤4) around `URLSession` calls plus batching; a 429 with reason `concurrent`/`rateLimitExceeded` is retryable with backoff.
