import XCTest

@testable import MailCore

final class BackoffTests: XCTestCase {

    func testTransientTable() {
        let d = (1...6).map { Backoff.transient.delay(attempt: $0, retryAfter: nil, random: 0.5) }
        XCTAssertEqual(d, [1, 2, 4, 8, 16, 16])
    }

    func testOutboxTable() {
        let d = (1...10).map { Backoff.outbox.delay(attempt: $0, retryAfter: nil, random: 0.5) }
        XCTAssertEqual(d, [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
    }

    func testJitterBounds() {
        XCTAssertEqual(Backoff.outbox.delay(attempt: 3, retryAfter: nil, random: 0), 6.0, accuracy: 0.01)
        XCTAssertEqual(Backoff.outbox.delay(attempt: 3, retryAfter: nil, random: 0.999), 9.998, accuracy: 0.01)
        XCTAssertEqual(Backoff.outbox.delay(attempt: 3, retryAfter: nil, random: 0.5), 8, accuracy: 0.01)
    }

    func testRetryAfterWins() {
        XCTAssertEqual(Backoff.transient.delay(attempt: 9, retryAfter: 42, random: 0), 42)
    }

    func testAttemptZeroTreatedAsOne() {
        let one = Backoff.transient.delay(attempt: 1, retryAfter: nil, random: 0.5)
        XCTAssertEqual(Backoff.transient.delay(attempt: 0, retryAfter: nil, random: 0.5), one)
        XCTAssertEqual(Backoff.transient.delay(attempt: -3, retryAfter: nil, random: 0.5), one)
    }

    func testCapReached() {
        XCTAssertEqual(Backoff.outbox.delay(attempt: 50, retryAfter: nil, random: 0.5), 300)
    }

    func testEquatable() {
        XCTAssertEqual(Backoff.transient, Backoff(base: 1, factor: 2, cap: 16, jitter: 0.25))
    }
}
