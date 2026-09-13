import Foundation
import XCTest

enum HTMLFixtures {
    static func load(_ name: String) -> String {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures/html"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            XCTFail("missing fixture \(name).html")
            return ""
        }
        return text
    }
}
