import UIKit
import XCTest

@testable import minimail

final class BundleConfigTests: XCTestCase {

    private var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    func testBackgroundKeys() {
        XCTAssertEqual(info["BGTaskSchedulerPermittedIdentifiers"] as? [String], ["de.newtelco.minimail.refresh"])
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["fetch"])
    }

    func testLaunchScreenColor() {
        let launch = info["UILaunchScreen"] as? [String: Any]
        XCTAssertEqual(launch?["UIColorName"] as? String, "LaunchBackground")
        XCTAssertNotNil(UIColor(named: "LaunchBackground"))
    }

    func testOAuthKeys() throws {
        let clientID = try XCTUnwrap(info["GoogleClientID"] as? String)
        XCTAssertTrue(clientID.hasSuffix(".apps.googleusercontent.com"))

        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = try XCTUnwrap(urlTypes.first?["CFBundleURLSchemes"] as? [String])
        XCTAssertTrue(try XCTUnwrap(schemes.first).hasPrefix("com.googleusercontent.apps."))
    }

    func testDisplayAndCategory() {
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "minimail")
        XCTAssertEqual(info["LSApplicationCategoryType"] as? String, "public.app-category.productivity")
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.1.0")
    }

    func testPrivacyManifestBundled() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            options: [],
            format: nil
        )
        let dict = try XCTUnwrap(plist as? [String: Any])
        let types = try XCTUnwrap(dict["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let first = try XCTUnwrap(types.first)
        XCTAssertEqual(first["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
        XCTAssertEqual(first["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }

    func testAccentColorAsset() {
        XCTAssertNotNil(UIColor(named: "AccentColor"))
    }

    func testFixtureFolderCopied() {
        let url = Bundle(for: Self.self)
            .url(forResource: "smoke", withExtension: "json", subdirectory: "Fixtures/vectors")
        XCTAssertNotNil(url, "project.yml must copy the MailCore fixtures into the test bundle")
    }
}
