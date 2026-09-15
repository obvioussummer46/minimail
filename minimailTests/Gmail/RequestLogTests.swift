import Foundation
import XCTest

@testable import minimail

nonisolated final class RequestLogTests: XCTestCase {

    func testRingBufferCapacity() {
        let log = RequestLog()
        for i in 0..<105 { log.record(method: "GET", path: "p\(i)", status: 200, ms: 1) }
        let entries = log.entries()
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(entries.first?.path, "p5")
        XCTAssertEqual(entries.last?.path, "p104")
    }

    func testSnapshotFormat() {
        let log = RequestLog()
        log.record(method: "GET", path: "profile?prettyPrint=false", status: 200, ms: 87)
        let line = log.snapshot()[0]
        XCTAssertTrue(line.hasSuffix(" GET profile?prettyPrint=false 200 87ms"), line)
        XCTAssertNotNil(line.range(of: #"^\d{2}:\d{2}:\d{2}\.\d{3} "#, options: .regularExpression), line)
    }
}
