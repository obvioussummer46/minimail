import GRDB
import MailCore
import SwiftUI
import XCTest

@testable import minimail

/// Spec 13 §7.2. Everything here drives `SignatureEditorModel` directly: the screen is a thin shell over it.
nonisolated final class SignatureEditorModelTests: XCTestCase {
    private var env: AppEnvironment!

    @MainActor override func setUp() async throws {
        env = AppEnvironment(testing: true)
    }

    @MainActor override func tearDown() async throws {
        env = nil
    }

    @MainActor
    private func makeModel() -> SignatureEditorModel {
        let theme = env.theme.resolved(for: .light)
        return SignatureEditorModel(
            env: env, light: theme.cssTokens(for: .light), dark: theme.cssTokens(for: .dark), forcedScheme: nil)
    }

    @MainActor
    private func storeGmailSignature(_ html: String?) async throws {
        try await env.db.write { try SyncStateRepository.set($0, .sendAsSignature, html) }
    }

    // MARK: - load

    @MainActor
    func testLoadCopiesSettings() async {
        env.settings.update { $0.signatureHTML = "<div>Max</div>" }
        let model = makeModel()
        model.load()
        XCTAssertEqual(model.html, "<div>Max</div>")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canSave)
        XCTAssertTrue(model.previewDocument.contains("Nothing to preview"))
    }

    // MARK: - preview

    @MainActor
    func testPreviewSanitizes() async throws {
        let model = makeModel()
        model.html = "<div>Max<script>alert(1)</script></div>"
        await model.refreshPreview()
        let sanitized = try XCTUnwrap(model.sanitized)
        XCTAssertFalse(sanitized.lowercased().contains("<script"))
        XCTAssertTrue(sanitized.contains("Max"))
        XCTAssertNil(model.error)
        XCTAssertTrue(model.previewDocument.contains(sanitized))
    }

    @MainActor
    func testPreviewKeepsHTTPSImage() async {
        let model = makeModel()
        model.html = "<img src=\"https://www.example.com/logo.png\" alt=\"Example\">"
        await model.refreshPreview()
        XCTAssertTrue(model.sanitized?.contains("https://www.example.com/logo.png") ?? false)
        XCTAssertNil(model.warning)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testDataImageWarning() async {
        let model = makeModel()
        model.html = "<img src=\"data:image/png;base64,iVBORw0KGgo=\">"
        await model.refreshPreview()
        XCTAssertEqual(model.warning, SettingsStrings.dataImageWarning)
        XCTAssertNil(model.error)
        // The warning is advice, not a block.
        XCTAssertTrue(model.canSave)
    }

    @MainActor
    func testWarningClearsWhenImageRemoved() async {
        let model = makeModel()
        model.html = "<img src=\"data:image/png;base64,iVBORw0KGgo=\">"
        await model.refreshPreview()
        XCTAssertNotNil(model.warning)
        model.html = "<div>Max</div>"
        await model.refreshPreview()
        XCTAssertNil(model.warning)
    }

    @MainActor
    func testOversizeBlocksSave() async {
        let model = makeModel()
        model.html = String(repeating: "a", count: SignatureEditorModel.maxBytes + 1)
        await model.refreshPreview()
        XCTAssertEqual(model.error, SettingsStrings.signatureTooLarge)
        XCTAssertNil(model.sanitized)
        XCTAssertFalse(model.canSave)
    }

    @MainActor
    func testCIDImageLosesSource() async {
        let model = makeModel()
        model.html = "<img src=\"cid:logo@x\">"
        await model.refreshPreview()
        XCTAssertFalse(model.sanitized?.contains("cid:") ?? true)
    }

    /// A sanitize that finishes after a newer keystroke must not be published. Whether the detached task reads
    /// "one" or "two" depends on scheduling, so the invariant asserted is the one that always holds: the editor
    /// never shows a result for text that is no longer in it.
    @MainActor
    func testRefreshPreviewIgnoresStaleResult() async {
        let model = makeModel()
        model.html = "<div>one</div>"
        async let first: Void = model.refreshPreview()
        model.html = "<div>two</div>"
        await first
        XCTAssertFalse(model.sanitized?.contains("one") ?? false)
        await model.refreshPreview()
        XCTAssertTrue(model.sanitized?.contains("two") ?? false)
        XCTAssertFalse(model.sanitized?.contains("one") ?? true)
    }

    // MARK: - save

    @MainActor
    func testSaveWritesSanitizedHTML() async {
        let model = makeModel()
        model.load()
        model.html = "<div>Max<script>x</script></div>"
        await model.refreshPreview()
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(env.settings.snapshot.signatureHTML, model.sanitized)
        XCTAssertEqual(model.html, model.sanitized)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canSave)
    }

    @MainActor
    func testSaveInsideDebounceSanitizesFirst() async {
        let model = makeModel()
        model.load()
        model.html = "<b>Max</b>"
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertTrue(env.settings.snapshot.signatureHTML.contains("Max"))
        XCTAssertNotNil(model.sanitized)
    }

    /// Editing after a preview and saving before the next debounce fires must store the new text, not the
    /// previously sanitized one.
    @MainActor
    func testSaveAfterEditReSanitizes() async {
        let model = makeModel()
        model.load()
        model.html = "<b>Alpha</b>"
        await model.refreshPreview()
        model.html = "<i>Beta</i>"
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertTrue(env.settings.snapshot.signatureHTML.contains("Beta"))
        XCTAssertFalse(env.settings.snapshot.signatureHTML.contains("Alpha"))
    }

    @MainActor
    func testSaveBlockedByError() async {
        let model = makeModel()
        model.load()
        model.html = String(repeating: "a", count: SignatureEditorModel.maxBytes + 1)
        await model.refreshPreview()
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(env.settings.snapshot.signatureHTML, "")
    }

    @MainActor
    func testIsDirtyRules() {
        env.settings.update { $0.signatureHTML = "<div>A</div>" }
        let model = makeModel()
        model.load()
        XCTAssertFalse(model.isDirty)
        model.html = "<div>B</div>"
        XCTAssertTrue(model.isDirty)
        model.html = "<div>A</div>"
        XCTAssertFalse(model.isDirty)
    }

    // MARK: - import

    @MainActor
    func testImportFromGmail() async throws {
        try await storeGmailSignature("<div dir=\"ltr\">Gmail Sig</div>")
        let model = makeModel()
        model.load()
        await model.importFromGmail()
        XCTAssertEqual(model.html, "<div dir=\"ltr\">Gmail Sig</div>")
        XCTAssertEqual(model.importState, .imported)
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testImportUnavailable() async {
        let model = makeModel()
        model.load()
        model.html = "<div>Mine</div>"
        await model.importFromGmail()
        XCTAssertEqual(model.importState, .unavailable)
        XCTAssertEqual(model.html, "<div>Mine</div>")
    }

    @MainActor
    func testImportBlankIsUnavailable() async throws {
        try await storeGmailSignature("\n  \n")
        let model = makeModel()
        model.load()
        await model.importFromGmail()
        XCTAssertEqual(model.importState, .unavailable)
    }

    /// The imported HTML is raw Gmail markup: it is sanitized only when the owner saves.
    @MainActor
    func testImportedSignatureIsSanitizedOnSave() async throws {
        try await storeGmailSignature("<div>Gmail<script>alert(1)</script></div>")
        let model = makeModel()
        model.load()
        await model.importFromGmail()
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(env.settings.snapshot.signatureHTML.lowercased().contains("<script"))
        XCTAssertTrue(env.settings.snapshot.signatureHTML.contains("Gmail"))
    }
}
