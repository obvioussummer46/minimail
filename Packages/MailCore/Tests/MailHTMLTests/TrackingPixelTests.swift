import SwiftSoup
import XCTest

@testable import MailHTML

final class TrackingPixelTests: XCTestCase {
    func testMatrix() throws {
        let doc = try SwiftSoup.parseBodyFragment(HTMLFixtures.load("tracking-pixels"), "")
        let imgs = try doc.select("img").array()
        let results = try imgs.map { TrackingPixel.isTracking($0, src: try $0.attr("src")) }
        XCTAssertEqual(results, [true, true, true, false, false, false, false, true, false])
    }

    func testPixelParsers() {
        XCTAssertEqual(TrackingPixel.pixels("12px"), 12)
        XCTAssertEqual(TrackingPixel.pixels(" 3 "), 3)
        XCTAssertNil(TrackingPixel.pixels("50%"))
        XCTAssertNil(TrackingPixel.pixels("auto"))
        XCTAssertNil(TrackingPixel.pixels(""))
        XCTAssertEqual(TrackingPixel.cssPixels(style: "min-width:1px;width:200px", property: "width"), 200)
        XCTAssertEqual(TrackingPixel.cssPixels(style: "WIDTH : 1PX", property: "width"), 1)
    }
}
