//
//  SupportRequestTests.swift
//  MLBrowserUnitTests
//
//  Structured support requests (AIA-0440 Stage 1, AIA-0454).
//

import CryptoKit
import SupportLogFormat
import XCTest
@testable import ML_Browser

/// `SupportRequest` decides what leaves the device, so these tests read the actual output rather
/// than trusting the doc comment. The lesson is AIA-0441's: the analytics claims were verifiable
/// only because the payload was built from named fields, and a comment asserting an invariant the
/// code does not hold is worse than no comment.
final class SupportRequestTests: XCTestCase {
	private func makeRequest(
		category: SupportCategory = .bug,
		contextURL: String? = nil,
		accountID: String? = nil
	) -> SupportRequest {
		SupportRequest(
			category: category,
			contextURL: contextURL,
			accountID: accountID,
			appLanguage: "en",
			appVersion: "1.0.7",
			deviceInformation: "Device Model: iPhone16,1\niOS Version: 26.0\nApp Build Number: 123"
		)
	}

	// MARK: - Subject

	func testSubject_CarriesCategoryRawValue_NotDisplayName() {
		let subject = makeRequest(category: .featureRequest).subject
		XCTAssertTrue(
			subject.contains("[featureRequest]"),
			"the subject must carry the stable rawValue tag so inbox filters key off something that "
				+ "survives a rename and does not vary by the sender's language"
		)
		XCTAssertFalse(subject.contains("Feature request"), "the localized name belongs in the body, not the tag")
	}

	func testSubject_CarriesAppVersion_ForTriage() {
		XCTAssertTrue(makeRequest().subject.contains("1.0.7"))
	}

	// MARK: - Body: the named fields

	func testBody_IncludesNamedDiagnosticFields() {
		let body = makeRequest().body
		XCTAssertTrue(body.contains("iPhone16,1"), "device model")
		XCTAssertTrue(body.contains("26.0"), "iOS version")
		XCTAssertTrue(body.contains("123"), "build number")
		XCTAssertTrue(body.contains("en"), "app language")
		XCTAssertTrue(body.contains(L10n.Support.Category.bug), "the human-readable category")
	}

	func testBody_PutsTheUsersTypingSpaceFirst() {
		let body = makeRequest().body
		let promptIndex = body.range(of: L10n.Support.Body.describePrompt)?.lowerBound
		let detailsIndex = body.range(of: L10n.Support.Body.detailsHeader)?.lowerBound
		let prompt = try? XCTUnwrap(promptIndex)
		let details = try? XCTUnwrap(detailsIndex)
		XCTAssertNotNil(prompt)
		XCTAssertNotNil(details)
		if let prompt, let details {
			XCTAssertLessThan(
				prompt, details,
				"a composer puts the cursor at the top; burying the prompt under diagnostics is how "
					+ "you get empty reports"
			)
		}
	}

	// MARK: - Body: the context URL

	func testBody_IncludesContextURL_WhenProvided() {
		let body = makeRequest(contextURL: "https://example.com/thing?id=7").body
		XCTAssertTrue(
			body.contains("https://example.com/thing?id=7"),
			"the URL is the single most useful clue for a browser/download bug and the user reviews "
				+ "the body before sending — do not 'fix' this by stripping it (AIA-0454)"
		)
		XCTAssertTrue(body.contains(L10n.Support.Body.webAddress), "and it must be labelled, not smuggled in")
	}

	func testBody_OmitsWebAddressSection_WhenNoContextURL() {
		XCTAssertFalse(makeRequest(contextURL: nil).body.contains(L10n.Support.Body.webAddress))
	}

	func testBody_OmitsWebAddressSection_WhenContextURLIsEmpty() {
		XCTAssertFalse(
			makeRequest(contextURL: "").body.contains(L10n.Support.Body.webAddress),
			"an empty string must not render a dangling label"
		)
	}

	// MARK: - Body: the account identifier

	func testBody_OmitsAccount_WhenSignedOut() {
		XCTAssertFalse(makeRequest(accountID: nil).body.contains(L10n.Support.Body.account))
	}

	func testBody_IncludesAccount_WhenSignedIn() {
		let body = makeRequest(accountID: "user_2abc").body
		XCTAssertTrue(body.contains("user_2abc"))
		XCTAssertTrue(body.contains(L10n.Support.Body.account))
	}

	// MARK: - Categories

	func testCategories_AreTheSixSpecified() {
		XCTAssertEqual(
			Set(SupportCategory.allCases.map(\.rawValue)),
			["bug", "purchase", "account", "featureRequest", "privacy", "other"],
			"AIA-0440 specifies exactly these; the rawValues are the support inbox's filter contract"
		)
	}

	func testCategories_HaveDistinctDisplayNames() {
		let names = SupportCategory.allCases.map(\.displayName)
		XCTAssertEqual(Set(names).count, names.count, "a duplicated label makes the picker unusable")
	}
}

/// The screenshot-offer decision (AIA-0454). `nil` keeps asking until the user chooses; `true`
/// keeps offers enabled and `false` silences them. It lives in a pure function so the three
/// persisted states are pinned down rather than smoke-tested.
final class ScreenshotReportGateTests: XCTestCase {
	func testShouldOffer_WhenNoDecisionHasBeenStored() {
		XCTAssertTrue(ScreenshotReportGate.shouldOffer(flagEnabled: true, screenshotDetectionEnabled: nil))
	}

	func testShouldOffer_RequiresTheFlag() {
		XCTAssertFalse(
			ScreenshotReportGate.shouldOffer(flagEnabled: false, screenshotDetectionEnabled: nil),
			"turning the ConfigCat value off must silence the offer remotely, even on a fresh install"
		)
	}

	func testShouldOffer_AfterTheUserEnablesScreenshotDetection() {
		XCTAssertTrue(
			ScreenshotReportGate.shouldOffer(flagEnabled: true, screenshotDetectionEnabled: true),
			"an affirmative answer keeps offers enabled for later screenshots"
		)
	}

	func testShouldOffer_NeverAfterTheUserDisablesScreenshotDetection() {
		XCTAssertFalse(
			ScreenshotReportGate.shouldOffer(flagEnabled: true, screenshotDetectionEnabled: false),
			"an explicit 'don't ask again' disables screenshot detection until the user re-enables it"
		)
	}
}

final class ScreenshotAttachmentValidatorTests: XCTestCase {
	func testIsLargeEnough_AcceptsAnImageAtTheMinimumShortestSide() {
		XCTAssertTrue(ScreenshotAttachmentValidator.isLargeEnough(pixelWidth: 720, pixelHeight: 1_280))
		XCTAssertTrue(ScreenshotAttachmentValidator.isLargeEnough(pixelWidth: 1_280, pixelHeight: 720))
	}

	func testIsLargeEnough_RejectsAnImageBelowTheMinimumShortestSide() {
		XCTAssertFalse(ScreenshotAttachmentValidator.isLargeEnough(pixelWidth: 719, pixelHeight: 1_280))
		XCTAssertFalse(ScreenshotAttachmentValidator.isLargeEnough(pixelWidth: 1_280, pixelHeight: 719))
	}

	func testValidationResult_ReportsUnreadableImageDataSeparately() {
		XCTAssertEqual(
			ScreenshotAttachmentValidator.validationResult(imageData: Data("not an image".utf8)),
			.unreadable
		)
	}
}

final class SupportLogAttachmentTests: XCTestCase {

	/// AIA-0643 replaced this whole area. The tests that used to live here pinned the behaviour the
	/// ticket removed: a `text/plain` attachment below a one-MiB threshold, a `.zip` above it, and a
	/// filename ending `-unredacted.txt` so a recipient could tell the two apart. None of those
	/// survive — there is one sealed format at every size, and the redaction flag moved inside the
	/// envelope precisely so the filename stops announcing it.
	///
	/// What is asserted now is the property that replaced them: **whatever goes in, nothing readable
	/// comes out, and a failure produces no attachment rather than a plain-text one.**

	private var recipient = Curve25519.KeyAgreement.PrivateKey()

	private var sealer: SupportLogSealer {
		SupportLogSealer(
			publicKeyBase64URL: SupportLogKeyCoding.base64URLEncoded(recipient.publicKey.rawRepresentation),
			keyID: "1"
		)!
	}

	/// Log-shaped bytes: repetitive like a real log, and carrying a marker that must not survive.
	private func makeLogData(byteCount: Int) -> Data {
		let line = Data("[info] [ui] opened https://example.com/models/resnet50 — cache hit\n".utf8)
		var data = Data()
		data.reserveCapacity(byteCount + line.count)
		while data.count < byteCount {
			data.append(line)
		}
		return Data(data.prefix(byteCount))
	}

	// MARK: - Mail attachment

	/// Previously this asserted `nil` for empty data, then a plain-text placeholder. Dropping the
	/// attachment silently is what made "quiet session" and "the log was lost" look identical to
	/// whoever reads the report (AIA-0602), so an empty log still ships one line saying so — but
	/// sealed like everything else, so there is exactly one output format and no readable special
	/// case.
	func testApplicationLogAttachment_ExplainsItselfWhenTheLogIsEmpty() throws {
		let attachment = try XCTUnwrap(
			SupportRequestView.applicationLogAttachment(
				data: Data(), sendUnredactedData: false, sealer: sealer
			)
		)

		let opened = try SupportLogEnvelope.open(attachment.data, with: recipient)
		let text = try XCTUnwrap(String(bytes: opened.log, encoding: .utf8))
		XCTAssertTrue(
			text.contains("empty or unavailable"),
			"The placeholder has to say which, or it is no better than no attachment"
		)
	}

	func testApplicationLogAttachment_CarriesTheLogSealed() throws {
		let data = Data("latest log entry\n".utf8)

		let attachment = try XCTUnwrap(
			SupportRequestView.applicationLogAttachment(
				data: data, sendUnredactedData: true, sealer: sealer
			)
		)

		XCTAssertEqual(attachment.mimeType, "application/octet-stream")
		XCTAssertNotEqual(attachment.data, data, "the attachment must not be the plain log")
		XCTAssertEqual(try SupportLogEnvelope.open(attachment.data, with: recipient).log, data)
	}

	/// The case the deleted threshold used to govern. A full five-MiB log now takes the same path as
	/// a one-line one; the only thing size still affects is how well it compresses.
	func testApplicationLogAttachment_SealsAFullSizedLogAndLeavesNothingReadable() throws {
		let data = makeLogData(byteCount: 5 * 1_024 * 1_024)

		let attachment = try XCTUnwrap(
			SupportRequestView.applicationLogAttachment(
				data: data, sendUnredactedData: false, sealer: sealer
			)
		)

		XCTAssertNil(
			attachment.data.range(of: Data("example.com".utf8)),
			"a web address from the log must not be readable in the attachment"
		)
		XCTAssertLessThan(
			attachment.data.count, data.count,
			"compression is unconditional now, so a five-MiB log must still arrive far smaller"
		)
		XCTAssertEqual(try SupportLogEnvelope.open(attachment.data, with: recipient).log, data)
	}

	func testApplicationLogAttachment_NameNeverStatesTheRedactionChoice() throws {
		let unredacted = try XCTUnwrap(
			SupportRequestView.applicationLogAttachment(
				data: makeLogData(byteCount: 4_096), sendUnredactedData: true, sealer: sealer
			)
		)

		XCTAssertFalse(unredacted.fileName.contains("unredacted"))
		XCTAssertTrue(unredacted.fileName.hasSuffix(".aialog"), "got \(unredacted.fileName)")
		XCTAssertFalse(
			try SupportLogEnvelope.open(unredacted.data, with: recipient).metadata.redacted,
			"the choice still has to reach support — sealed, where only they can read it"
		)
	}

	// MARK: - Share/export (AIA-0602, resealed by AIA-0643)

	func testExportedApplicationLogFile_WritesSealedBytes() throws {
		defer { SupportRequestView.removeApplicationLogExports() }
		let data = Data("latest log entry\n".utf8)

		let url = try XCTUnwrap(
			SupportRequestView.exportedApplicationLogFile(
				data: data, sendUnredactedData: false, sealer: sealer
			)
		)

		let written = try Data(contentsOf: url)
		XCTAssertTrue(url.lastPathComponent.hasSuffix(".aialog"), "got \(url.lastPathComponent)")
		XCTAssertNotEqual(written, data, "the shared file must not be the plain log")
		XCTAssertEqual(try SupportLogEnvelope.open(written, with: recipient).log, data)
	}

	/// The share route used to be the readable one, on the reasoning that "save it to Files" is
	/// where readability is the point. It is not an exception any more — the user's own copy is as
	/// opaque as ours.
	func testExportedApplicationLogFile_IsNotReadableByTheUser() throws {
		defer { SupportRequestView.removeApplicationLogExports() }

		let url = try XCTUnwrap(
			SupportRequestView.exportedApplicationLogFile(
				data: makeLogData(byteCount: 8_192), sendUnredactedData: true, sealer: sealer
			)
		)

		let written = try Data(contentsOf: url)
		XCTAssertNil(written.range(of: Data("example.com".utf8)))
		XCTAssertFalse(url.lastPathComponent.contains("unredacted"))
	}

	func testRemoveApplicationLogExports_LeavesNoFileBehind() throws {
		let url = try XCTUnwrap(
			SupportRequestView.exportedApplicationLogFile(
				data: Data("latest log entry\n".utf8), sendUnredactedData: true, sealer: sealer
			)
		)

		SupportRequestView.removeApplicationLogExports()

		XCTAssertFalse(
			FileManager.default.fileExists(atPath: url.path),
			"an export must not outlive the toggle that produced it"
		)
	}

	/// Files an older build wrote are readable and survive the upgrade, because iOS does not wipe
	/// `tmp` and the in-sheet cleanup only runs if the user opens the Support form.
	func testPurgeLegacyApplicationLogExports_RemovesReadableFilesLeftByOlderBuilds() throws {
		let fileManager = FileManager.default
		let staging = fileManager.temporaryDirectory
			.appendingPathComponent("mlbrowser-log-zip-\(UUID().uuidString)", isDirectory: true)
		try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
		let strandedZipCopy = staging.appendingPathComponent("mlbrowser-application-log.txt")
		try Data("readable unredacted log\n".utf8).write(to: strandedZipCopy)

		let legacyExport = fileManager.temporaryDirectory
			.appendingPathComponent("support-log-export", isDirectory: true)
		try fileManager.createDirectory(at: legacyExport, withIntermediateDirectories: true)
		let strandedExport = legacyExport.appendingPathComponent("mlbrowser-application-log-unredacted.txt")
		try Data("readable unredacted log\n".utf8).write(to: strandedExport)

		SupportRequestView.purgeLegacyApplicationLogExports()

		XCTAssertFalse(fileManager.fileExists(atPath: strandedExport.path), "old plain export survived")
		XCTAssertFalse(fileManager.fileExists(atPath: strandedZipCopy.path), "old zip staging copy survived")
	}
}
