import XCTest

@testable import minimail

nonisolated final class OAuthConfigTests: XCTestCase {

    func testRedirectFromClientID() {
        let config = OAuthConfig(clientID: "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(config.redirectURL.absoluteString, "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(config.redirectURL.scheme, "com.googleusercontent.apps.123-abc")
    }

    func testRedirectWithoutSuffix() {
        let config = OAuthConfig(clientID: "raw")
        XCTAssertEqual(config.redirectURL.absoluteString, "com.googleusercontent.apps.raw:/oauth2redirect")
    }

    func testEndpointsAndScope() {
        let config = OAuthConfig(clientID: "123.apps.googleusercontent.com")
        XCTAssertEqual(config.authorizationEndpoint.absoluteString, "https://accounts.google.com/o/oauth2/v2/auth")
        XCTAssertEqual(config.tokenEndpoint.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(config.revocationEndpoint.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(config.scopes, ["https://www.googleapis.com/auth/gmail.modify"])
        XCTAssertNil(config.hostedDomain)
    }

    func testPlaceholderDetection() {
        XCTAssertTrue(OAuthConfig(clientID: "REPLACE.apps.googleusercontent.com").isPlaceholder)
        XCTAssertTrue(OAuthConfig(clientID: "").isPlaceholder)
        XCTAssertFalse(OAuthConfig(clientID: "123.apps.googleusercontent.com").isPlaceholder)
    }

    func testFromInfoPlistReadsBundle() {
        let config = OAuthConfig.fromInfoPlist(bundle: .main)
        let expected = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String
        XCTAssertEqual(config.clientID, expected?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testFromInfoPlistMissingKeyFallsBack() {
        let config = OAuthConfig.fromInfoPlist(bundle: Bundle(for: Self.self))
        XCTAssertTrue(config.isPlaceholder)
    }

    func testSchemeMatchesBundleURLScheme() throws {
        let config = OAuthConfig.fromInfoPlist()
        let urlTypes = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = try XCTUnwrap(urlTypes.first?["CFBundleURLSchemes"] as? [String])
        XCTAssertEqual(config.redirectURL.scheme, schemes.first)
    }

    func testServiceConfiguration() {
        let config = OAuthConfig(clientID: "123.apps.googleusercontent.com")
        let service = config.serviceConfiguration
        XCTAssertEqual(service.authorizationEndpoint, config.authorizationEndpoint)
        XCTAssertEqual(service.tokenEndpoint, config.tokenEndpoint)
    }

    func testKeychainAccountConstants() {
        XCTAssertEqual(OAuthConfig.keychainAccount, "oauth.authState")
        XCTAssertEqual(OAuthConfig.testingKeychainAccount, "oauth.authState.testing")
    }
}
