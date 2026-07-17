//
//  SupportRequestTests.swift
//  MLBrowserUnitTests
//
//  Structured support requests (AIA-0440 Stage 1, AIA-0454).
//

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
