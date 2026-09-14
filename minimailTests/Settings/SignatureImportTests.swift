import GRDB
import MailCore
import XCTest

@testable import minimail

nonisolated final class SignatureImportTests: XCTestCase {
    private var env: AppEnvironment!

    @MainActor override func setUp() async throws {
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        env.settings.defaults.removeObject(forKey: SignatureImport.adoptedDefaultsKey)
        env = nil
    }

    @MainActor
    private func storeGmailSignature(_ html: String?) async throws {
        try await env.db.write { try SyncStateRepository.set($0, .sendAsSignature, html) }
    }

    @MainActor
    private func adopt() async {
        await SignatureImport.adoptGmailSignatureIfUnset(db: env.db, settings: env.settings)
    }

    @MainActor
    func testAdoptsGmailSignature() async throws {
        try await storeGmailSignature("<div dir=\"ltr\">Max Mustermann<br><b>ACME</b></div>")
        await adopt()
        XCTAssertTrue(env.settings.snapshot.signatureHTML.contains("Max Mustermann"))
        XCTAssertTrue(env.settings.snapshot.signatureHTML.contains("<b>ACME</b>"))
        XCTAssertTrue(env.settings.defaults.bool(forKey: SignatureImport.adoptedDefaultsKey))
    }

    /// The adopted HTML has been through the signature allowlist, which keeps https images but drops scripts.
    @MainActor
    func testAdoptedSignatureIsSanitized() async throws {
        try await storeGmailSignature(
            "<div>Max<script>alert(1)</script><img src=\"https://cdn.example/logo.png\"></div>")
        await adopt()
        let html = env.settings.snapshot.signatureHTML
        XCTAssertFalse(html.lowercased().contains("<script"))
        XCTAssertTrue(html.contains("https://cdn.example/logo.png"))
    }

    @MainActor
    func testDoesNothingWithoutAGmailSignature() async throws {
        await adopt()
        XCTAssertEqual(env.settings.snapshot.signatureHTML, "")
        XCTAssertFalse(env.settings.defaults.bool(forKey: SignatureImport.adoptedDefaultsKey))
    }

    @MainActor
    func testBlankGmailSignatureIsNotAdopted() async throws {
        try await storeGmailSignature("   \n  ")
        await adopt()
        XCTAssertEqual(env.settings.snapshot.signatureHTML, "")
        XCTAssertFalse(env.settings.defaults.bool(forKey: SignatureImport.adoptedDefaultsKey))
    }

    @MainActor
    func testNeverOverwritesAnExistingSignature() async throws {
        env.settings.update { $0.signatureHTML = "<div>Meine eigene</div>" }
        try await storeGmailSignature("<div>Aus Gmail</div>")
        await adopt()
        XCTAssertEqual(env.settings.snapshot.signatureHTML, "<div>Meine eigene</div>")
    }

    /// Once adopted, clearing the signature is the owner's decision and the next sync must not undo it.
    @MainActor
    func testRunsOnlyOnce() async throws {
        try await storeGmailSignature("<div>Aus Gmail</div>")
        await adopt()
        XCTAssertFalse(env.settings.snapshot.signatureHTML.isEmpty)

        env.settings.update { $0.signatureHTML = "" }
        await adopt()
        XCTAssertEqual(env.settings.snapshot.signatureHTML, "")
    }

    /// End to end: what `OutboxIdentitySource` hands the MIME builder after the adoption.
    @MainActor
    func testAdoptedSignatureReachesTheOutgoingBody() async throws {
        try await storeGmailSignature("<div dir=\"ltr\">Max Mustermann</div>")
        await adopt()
        let (_, style, signature) = await env.identitySource.current()
        let html = OutgoingBodies.html(
            typed: "Ja, passt.", style: style, signatureHTML: signature, quoteHTML: nil)
        XCTAssertTrue(html.contains("Max Mustermann"))
        XCTAssertTrue(html.contains("gmail_signature"))
    }

    /// `signatureEnabled == false` means the identity source withholds it even though it is stored.
    @MainActor
    func testDisabledSignatureIsWithheld() async throws {
        try await storeGmailSignature("<div>Max Mustermann</div>")
        await adopt()
        env.settings.update { $0.signatureEnabled = false }
        let (_, _, signature) = await env.identitySource.current()
        XCTAssertNil(signature)
    }
}
