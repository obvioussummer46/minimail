import Foundation
import GRDB
import MailCore
import UIKit

/// Main-actor façade for the four user actions (architecture §4.8 "Enqueue"). Value type.
struct MailActions {
    let db: any DatabaseWriter
    let outbox: Outbox
    let sync: SyncEngine

    /// remove INBOX
    func archive(threadId: String) async { await modify(threadId, LabelDelta(add: [], remove: ["INBOX"])) }
    /// remove UNREAD
    func markRead(threadId: String) async { await modify(threadId, LabelDelta(add: [], remove: ["UNREAD"])) }
    /// add UNREAD
    func markUnread(threadId: String) async { await modify(threadId, LabelDelta(add: ["UNREAD"], remove: [])) }

    private func modify(_ threadId: String, _ delta: LabelDelta) async {
        let now = Self.nowMs()
        do {
            try await db.write { db in
                let ids = try ThreadRepository.messageIds(db, threadId: threadId)
                guard !ids.isEmpty else { return }
                _ = try OutboxRepository.enqueueModify(
                    db, threadId: threadId, delta: delta, affectedMessageIds: ids, now: now)
            }
        } catch {
            Log.outbox.error("enqueue failed: \(String(describing: error), privacy: .public)")
        }
        await outbox.kick()
    }

    /// write { enqueueSend } → beginBackgroundTask → drain → endBackgroundTask
    func send(_ job: SendJob) async {
        let now = Self.nowMs()
        do {
            _ = try await db.write { try OutboxRepository.enqueueSend($0, job: job, now: now) }
        } catch {
            Log.outbox.error("enqueueSend failed")
            return
        }
        let bgTask = BackgroundTask()
        bgTask.id = UIApplication.shared.beginBackgroundTask(withName: "com.minimail.send") {
            bgTask.end()
        }
        await outbox.drain()
        bgTask.end()
    }

    /// Boxes the identifier so the expiration handler and the normal path can each end the task once.
    @MainActor private final class BackgroundTask {
        var id = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
