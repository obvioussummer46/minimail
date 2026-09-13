import XCTest

@testable import MailCore

final class HydrationPolicyTests: XCTestCase {

    private func ref(thread: String? = nil, labels: [String]?) -> GmailMessageRef {
        GmailMessageRef(id: "m", threadId: thread, labelIds: labels)
    }
    private func scope(cached: Set<String> = [], known: Set<String> = []) -> HydrationScope {
        HydrationScope(cachedLabelIds: cached, knownThreadIds: known)
    }

    func testNilLabelsFetches() {
        XCTAssertTrue(HydrationPolicy.shouldFetch(ref: ref(labels: nil), scope: scope()))
    }

    func testKnownThreadFetches() {
        XCTAssertTrue(
            HydrationPolicy.shouldFetch(ref: ref(thread: "t1", labels: ["SPAM"]), scope: scope(known: ["t1"])))
    }

    func testInboxFetches() {
        XCTAssertTrue(HydrationPolicy.shouldFetch(ref: ref(labels: ["INBOX"]), scope: scope(cached: ["INBOX"])))
    }

    func testCachedLabelFetches() {
        XCTAssertTrue(
            HydrationPolicy.shouldFetch(ref: ref(labels: ["Label_12"]), scope: scope(cached: ["INBOX", "Label_12"])))
    }

    func testSpamOnlySkipped() {
        XCTAssertFalse(
            HydrationPolicy.shouldFetch(ref: ref(labels: ["SPAM", "UNREAD"]), scope: scope(cached: ["INBOX"])))
    }

    func testEmptyLabelsSkipped() {
        XCTAssertFalse(HydrationPolicy.shouldFetch(ref: ref(labels: []), scope: scope(cached: ["INBOX"])))
    }

    func testNilThreadIdNotKnown() {
        XCTAssertFalse(
            HydrationPolicy.shouldFetch(ref: ref(thread: nil, labels: ["Label_9"]), scope: scope(known: ["x"])))
    }

    func testSentReplyInKnownThread() {
        XCTAssertTrue(
            HydrationPolicy.shouldFetch(ref: ref(thread: "t1", labels: ["SENT"]), scope: scope(known: ["t1"])))
    }
}
