import Foundation
import GRDB

/// The SQLite schema (migration `v1`). `v1SQL` is the verbatim DDL of spec §5.1.
nonisolated enum Schema {
    static let tableNames = [
        "label", "thread", "thread_label", "message", "message_body", "attachment", "outbox", "syncState",
    ]
    static let indexNames = [
        "thread_inbox_date", "thread_inbox_unread", "thread_inbox_today", "thread_label_date",
        "message_thread_date", "message_generation", "outbox_due", "outbox_thread",
    ]

    /// Fallback body when a message could not be displayed (architecture §9.1 step 7).
    static let unavailableBodyHTML = "<p><i>This message could not be displayed.</i></p>"

    static let v1SQL = """
        CREATE TABLE label (
          id                    TEXT PRIMARY KEY NOT NULL,
          name                  TEXT NOT NULL,
          type                  TEXT NOT NULL,
          labelListVisibility   TEXT,
          messageListVisibility TEXT,
          textColor             TEXT,
          backgroundColor       TEXT,
          messagesUnread        INTEGER,
          threadsUnread         INTEGER,
          threadsTotal          INTEGER,
          countsFetchedAt       INTEGER,
          sortOrder             INTEGER NOT NULL DEFAULT 1000,
          viewFetchedAt         INTEGER,
          viewNextPageToken     TEXT
        );

        CREATE TABLE thread (
          id              TEXT PRIMARY KEY NOT NULL,
          subject         TEXT NOT NULL DEFAULT '',
          snippet         TEXT NOT NULL DEFAULT '',
          lastDate        INTEGER NOT NULL,
          lastInboxDate   INTEGER,
          messageCount    INTEGER NOT NULL,
          unreadCount     INTEGER NOT NULL,
          inInbox         INTEGER NOT NULL,
          hasAttachments  INTEGER NOT NULL,
          participants    TEXT NOT NULL DEFAULT '',
          userLabelIds    TEXT NOT NULL DEFAULT '[]',
          isComplete      INTEGER NOT NULL DEFAULT 0,
          bodiesMissing   INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX thread_inbox_date   ON thread(lastDate DESC)      WHERE inInbox = 1;
        CREATE INDEX thread_inbox_unread ON thread(lastDate DESC)      WHERE inInbox = 1 AND unreadCount > 0;
        CREATE INDEX thread_inbox_today  ON thread(lastInboxDate DESC) WHERE inInbox = 1;

        CREATE TABLE thread_label (
          labelId     TEXT NOT NULL,
          threadId    TEXT NOT NULL,
          lastDate    INTEGER NOT NULL,
          unreadCount INTEGER NOT NULL,
          PRIMARY KEY (labelId, threadId)
        ) WITHOUT ROWID;
        CREATE INDEX thread_label_date ON thread_label(labelId, lastDate DESC);

        CREATE TABLE message (
          id               TEXT PRIMARY KEY NOT NULL,
          threadId         TEXT NOT NULL,
          historyId        INTEGER NOT NULL DEFAULT 0,
          internalDate     INTEGER NOT NULL,
          fromName         TEXT,
          fromAddr         TEXT NOT NULL DEFAULT '',
          isFromMe         INTEGER NOT NULL DEFAULT 0,
          toList           TEXT NOT NULL DEFAULT '[]',
          ccList           TEXT NOT NULL DEFAULT '[]',
          replyToList      TEXT NOT NULL DEFAULT '[]',
          subject          TEXT NOT NULL DEFAULT '',
          snippet          TEXT NOT NULL DEFAULT '',
          messageIdHeader  TEXT,
          inReplyTo        TEXT,
          referencesList   TEXT NOT NULL DEFAULT '[]',
          topMimeType      TEXT,
          serverLabelIds   TEXT NOT NULL DEFAULT '[]',
          labelIds         TEXT NOT NULL DEFAULT '[]',
          isUnread         INTEGER NOT NULL DEFAULT 0,
          inInbox          INTEGER NOT NULL DEFAULT 0,
          isHidden         INTEGER NOT NULL DEFAULT 0,
          hasAttachments   INTEGER NOT NULL DEFAULT 0,
          bodyState        INTEGER NOT NULL DEFAULT 0,
          syncGeneration   INTEGER NOT NULL DEFAULT 0,
          fetchedAt        INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX message_thread_date ON message(threadId, internalDate);
        CREATE INDEX message_generation  ON message(syncGeneration);

        CREATE TABLE message_body (
          messageId        TEXT PRIMARY KEY NOT NULL REFERENCES message(id) ON DELETE CASCADE,
          bodyHtml         TEXT NOT NULL,
          bodyText         TEXT,
          hasRemoteImages  INTEGER NOT NULL DEFAULT 0,
          darkStrategy     TEXT NOT NULL DEFAULT 'plain',
          sanitizerVersion INTEGER NOT NULL,
          fetchedAt        INTEGER NOT NULL
        );

        CREATE TABLE attachment (
          messageId    TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
          partId       TEXT NOT NULL,
          filename     TEXT NOT NULL,
          mimeType     TEXT NOT NULL,
          size         INTEGER NOT NULL DEFAULT 0,
          contentId    TEXT,
          isInline     INTEGER NOT NULL DEFAULT 0,
          attachmentId TEXT,
          PRIMARY KEY (messageId, partId)
        ) WITHOUT ROWID;

        CREATE TABLE outbox (
          id                 INTEGER PRIMARY KEY AUTOINCREMENT,
          kind               TEXT NOT NULL,
          state              TEXT NOT NULL DEFAULT 'pending',
          attempts           INTEGER NOT NULL DEFAULT 0,
          nextAttemptAt      INTEGER NOT NULL DEFAULT 0,
          createdAt          INTEGER NOT NULL,
          lastError          TEXT,
          threadId           TEXT,
          addLabelIds        TEXT,
          removeLabelIds     TEXT,
          affectedMessageIds TEXT,
          sendJob            TEXT,
          rfc822MessageId    TEXT,
          transmitState      TEXT
        );
        CREATE INDEX outbox_due    ON outbox(state, nextAttemptAt);
        CREATE INDEX outbox_thread ON outbox(threadId) WHERE kind = 'modify';

        CREATE TABLE syncState (
          key   TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        ) WITHOUT ROWID;
        """

    static let dropAllSQL = """
        DROP TABLE IF EXISTS syncState;
        DROP TABLE IF EXISTS outbox;
        DROP TABLE IF EXISTS attachment;
        DROP TABLE IF EXISTS message_body;
        DROP TABLE IF EXISTS message;
        DROP TABLE IF EXISTS thread_label;
        DROP TABLE IF EXISTS thread;
        DROP TABLE IF EXISTS label;
        DELETE FROM sqlite_sequence WHERE name = 'outbox';
        """

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in try db.execute(sql: v1SQL) }
    }
}
