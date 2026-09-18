import MailCore
import SwiftUI
import UIKit
import XCTest

@testable import minimail

nonisolated final class InboxViewsTests: XCTestCase {

    func testThreadRowAccessibilityLabel() {
        let unread = ThreadRow(
            id: "t", participants: "Alice, Me", subject: "", snippet: "s", dateLabel: "14:32", isUnread: true,
            messageCount: 3, hasAttachments: true,
            chips: [ThreadChip(id: "L", name: "ACME", textColor: nil, backgroundColor: nil)])
        XCTAssertEqual(
            ThreadRowView.accessibilityLabel(for: unread),
            "Unread, Alice, Me, No subject, 14:32, 3 messages, Has attachment, Label ACME")

        let read = ThreadRow(
            id: "t", participants: "Alice, Me", subject: "Hi", snippet: "s", dateLabel: "14:32", isUnread: false,
            messageCount: 1, hasAttachments: false, chips: [])
        XCTAssertEqual(ThreadRowView.accessibilityLabel(for: read), "Alice, Me, Hi, 14:32")
    }

    func testLabelChipColorParsing() {
        XCTAssertNotNil(LabelChip.color(hex: "#ff0000"))
        XCTAssertNotNil(LabelChip.color(hex: "#FF0000"))
        XCTAssertNil(LabelChip.color(hex: "#ff000"))
        XCTAssertNil(LabelChip.color(hex: "ff0000"))
        XCTAssertNil(LabelChip.color(hex: "#gg0000"))
        XCTAssertNil(LabelChip.color(hex: nil))
        var blue: CGFloat = 0
        UIColor(LabelChip.color(hex: "#0000ff")!).getRed(nil, green: nil, blue: &blue, alpha: nil)
        XCTAssertEqual(blue, 1, accuracy: 0.01)
    }

    func testStatusBannerStrings() {
        XCTAssertEqual(StatusBanner.title(for: .offline), "Offline — changes will sync")
        XCTAssertEqual(StatusBanner.symbol(for: .offline), "wifi.slash")
        XCTAssertNil(StatusBanner.actionTitle(for: .offline))
        XCTAssertNil(StatusBanner.detail(for: .offline))

        XCTAssertEqual(StatusBanner.title(for: .reauth), "Sign in again to keep syncing")
        XCTAssertEqual(StatusBanner.symbol(for: .reauth), "person.crop.circle.badge.exclamationmark")
        XCTAssertEqual(StatusBanner.actionTitle(for: .reauth), "Sign in")
        XCTAssertNil(StatusBanner.detail(for: .reauth))

        XCTAssertEqual(StatusBanner.title(for: .error("x")), "Couldn’t refresh")
        XCTAssertEqual(StatusBanner.symbol(for: .error("x")), "exclamationmark.triangle")
        XCTAssertEqual(StatusBanner.actionTitle(for: .error("x")), "Retry")
        XCTAssertEqual(StatusBanner.detail(for: .error("x")), "x")
    }

    func testFailedSendRowStrings() {
        let job = Self.job(
            subject: "  ", to: [Mailbox(name: "Alice", addr: "a@x.de")], cc: [Mailbox(name: nil, addr: "b@x.de")])
        let rec = Self.record(job: job, lastError: nil)
        XCTAssertEqual(FailedSendRow.subject(for: rec), "(No subject)")
        XCTAssertEqual(FailedSendRow.recipients(for: rec), "To: Alice, b@x.de")
        XCTAssertEqual(FailedSendRow.errorLine(for: rec), "Not sent — Unknown error")

        let rec2 = Self.record(job: job, lastError: "Daily quota exceeded")
        XCTAssertEqual(FailedSendRow.errorLine(for: rec2), "Not sent — Daily quota exceeded")

        let noJob = Self.record(job: nil, lastError: nil)
        XCTAssertEqual(FailedSendRow.recipients(for: noJob), "To: —")
        XCTAssertEqual(FailedSendRow.subject(for: noJob), "(No subject)")
    }

    @MainActor
    func testComposeInputAndSheetIds() {
        XCTAssertEqual(
            ComposeInput.fromMessage(mode: .forward, threadId: "t", messageId: "m").id, "message:forward:m")
        let job = Self.job(subject: "s", to: [], cc: [])
        XCTAssertEqual(ComposeInput.failedSend(outboxId: 7, job: job).id, "failedSend:7")
        XCTAssertEqual(ActiveSheet.labels.id, "labels")
        XCTAssertEqual(ActiveSheet.settings.id, "settings")
        let a = ComposeInput.failedSend(outboxId: 7, job: job)
        XCTAssertEqual(ActiveSheet.compose(a).id, "compose:failedSend:7")
        XCTAssertEqual(ActiveSheet.compose(a), ActiveSheet.compose(a))
        XCTAssertNotEqual(ActiveSheet.labels, ActiveSheet.settings)
    }

    func testMailboxDotsAccentTheLastDotLikeTheIcon() {
        // The icon paints the third tittle in the accent; the toolbar mark must match it, not the scope.
        XCTAssertEqual(MailboxDots.accentIndex, MailboxDots.centers.count - 1)
    }

    func testMailboxDotsKeepsTheWordmarkRhythm() {
        let centers = MailboxDots.centers
        XCTAssertEqual(centers.count, 3)
        let gaps = zip(centers, centers.dropFirst()).map { $1 - $0 }
        // The tittles sit over letters 2, 4 and 7 of "minimail", so the gaps run 2:3. Evenly spaced dots
        // are an ellipsis, not the mark.
        XCTAssertEqual(gaps[1] / gaps[0], 1.5, accuracy: 0.001)
    }

    // MARK: builders

    static func job(subject: String, to: [Mailbox], cc: [Mailbox]) -> SendJob {
        SendJob(
            mode: .replyAll, originalMessageId: "m1", threadId: "t1", messageID: "<x@example.com>", to: to, cc: cc,
            subject: subject, typedText: "t", inReplyTo: nil, references: [],
            quoteSource: QuoteSource(
                author: nil, date: Date(timeIntervalSince1970: 1_757_500_000), subject: subject, to: [], cc: [],
                html: nil, text: nil),
            attachments: [], includeSignature: true)
    }

    static func record(job: SendJob?, lastError: String?) -> OutboxRecord {
        OutboxRecord(
            id: 1, kind: .send, state: .failed, attempts: 1, nextAttemptAt: 0, createdAt: 0, lastError: lastError,
            threadId: job?.threadId, addLabelIds: nil, removeLabelIds: nil, affectedMessageIds: nil, sendJob: job,
            rfc822MessageId: job?.messageID, transmitState: .notSent)
    }
}
