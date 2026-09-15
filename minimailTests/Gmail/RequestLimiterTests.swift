import Foundation
import XCTest

@testable import minimail

nonisolated final class RequestLimiterTests: XCTestCase {

    func testCapsAtMax() async {
        let limiter = RequestLimiter(max: 2)
        let counter = ConcurrencyCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await limiter.withPermit {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(50))
                        await counter.leave()
                    }
                }
            }
        }
        let maxSeen = await counter.maxSeen
        XCTAssertEqual(maxSeen, 2)
        let inUse = await limiter.inUse
        XCTAssertEqual(inUse, 0)
    }

    func testReleasesOnThrow() async {
        let limiter = RequestLimiter(max: 1)
        struct Boom: Error {}
        do {
            try await limiter.withPermit { throw Boom() }
            XCTFail("expected throw")
        } catch {}
        let inUse = await limiter.inUse
        XCTAssertEqual(inUse, 0)
        let ran = (try? await limiter.withPermit { true }) ?? false
        XCTAssertTrue(ran)
    }

    func testFIFO() async {
        let limiter = RequestLimiter(max: 1)
        let order = OrderRecorder()
        // Hold the single permit, queue three ops, then release by letting the first finish.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask {
                    // Stagger starts so they enqueue in order 0,1,2.
                    try? await Task.sleep(for: .milliseconds(20 * i))
                    try? await limiter.withPermit {
                        await order.record(i)
                        try await Task.sleep(for: .milliseconds(30))
                    }
                }
            }
        }
        let completed = await order.completed
        XCTAssertEqual(completed, [0, 1, 2])
    }
}

private actor ConcurrencyCounter {
    private var current = 0
    private(set) var maxSeen = 0
    func enter() {
        current += 1
        maxSeen = Swift.max(maxSeen, current)
    }
    func leave() { current -= 1 }
}

private actor OrderRecorder {
    private(set) var completed: [Int] = []
    func record(_ i: Int) { completed.append(i) }
}
