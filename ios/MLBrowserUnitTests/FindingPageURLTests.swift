//
//  FindingPageURLTests.swift
//  MLBrowserUnitTests
//
//  AIA-0817: which URL a finding stores once the field became editable.
//
//  The stake is higher than a wrong-looking field. `FindingRepository.save` turns a page-URL
//  validation failure into a thrown error that deletes the row and its screenshot, so an unstorable
//  URL reaching the entity loses the whole finding.
//

import XCTest
@testable import ML_Browser

final class FindingPageURLTests: XCTestCase {

	private let captured = URL(string: "https://ags.cuzk.gov.cz/av/")!

	// MARK: - Clearing

	/// An empty field is a decision, not an omission: the user wiped it, so nothing is stored.
	func testEmptyEdit_StoresNothing() {
		XCTAssertNil(FindingPageURL.resolve(edited: "", captured: captured))
		XCTAssertNil(FindingPageURL.resolve(edited: "   \n ", captured: captured))
	}

	// MARK: - A usable edit wins

	/// The whole point of making the field editable: correcting a URL the app resolved wrongly.
	func testUsableEdit_ReplacesTheCapturedURL() {
		let resolved = FindingPageURL.resolve(
			edited: "https://www.freemap.sk/#map=15/47.941230/18.709545",
			captured: captured
		)
		XCTAssertEqual(resolved?.absoluteString, "https://www.freemap.sk/#map=15/47.941230/18.709545")
	}

	func testSchemelessEdit_GetsHTTPS() {
		XCTAssertEqual(
			FindingPageURL.resolve(edited: "example.org/map", captured: nil)?.absoluteString,
			"https://example.org/map"
		)
	}

	func testHTTPEdit_IsKeptAsTyped() {
		XCTAssertEqual(
			FindingPageURL.resolve(edited: "http://example.org/map", captured: nil)?.absoluteString,
			"http://example.org/map"
		)
	}

	// MARK: - An unusable edit must not cost the page

	/// Punishing a typo by discarding the URL the app had correctly recorded would be the worst of
	/// both worlds, so the capture survives.
	func testUnusableEdit_FallsBackToTheCapturedURL() {
		XCTAssertEqual(FindingPageURL.resolve(edited: "not a url", captured: captured), captured)
		XCTAssertEqual(FindingPageURL.resolve(edited: "%%%", captured: captured), captured)
	}

	/// `Finding` forbids a file scheme outright; a user pasting one must not destroy the finding.
	func testFileURLEdit_IsRefusedAndFallsBack() {
		XCTAssertEqual(FindingPageURL.resolve(edited: "file:///etc/passwd", captured: captured), captured)
	}

	func testJavascriptURLEdit_IsRefused() {
		XCTAssertEqual(FindingPageURL.resolve(edited: "javascript:alert(1)", captured: captured), captured)
	}

	func testUnusableEdit_WithNoCapturedURL_StoresNothing() {
		XCTAssertNil(FindingPageURL.resolve(edited: "not a url", captured: nil))
	}

	// MARK: - An unstorable capture must not reach validation

	/// The UI-test harness loads `file://` fixtures. Before AIA-0817 that URL went straight to the
	/// entity, where validation would reject it and take the finding and its screenshot with it.
	func testFileCapture_BecomesNoPageRatherThanADeletedFinding() {
		let fixture = URL(string: "file:///tmp/uitest_page.html")!
		XCTAssertNil(FindingPageURL.storable(fixture))
		XCTAssertNil(FindingPageURL.resolve(edited: "", captured: fixture))
		XCTAssertNil(FindingPageURL.resolve(edited: "still not a url", captured: fixture))
	}

	func testAboutBlankCapture_IsNotStored() {
		XCTAssertNil(FindingPageURL.storable(URL(string: "about:blank")))
	}

	func testHostlessCapture_IsNotStored() {
		XCTAssertNil(FindingPageURL.storable(URL(string: "https:///nohost")))
	}

	func testOrdinaryCapture_IsStored() {
		XCTAssertEqual(FindingPageURL.storable(captured), captured)
	}

	// MARK: - The rule must match the entity's own

	/// Two copies of "is this a storable page URL" could drift, and the cost of drifting is a lost
	/// finding. This pins them together.
	func testStorable_AgreesWithTheEntityValidation() {
		let cases = [
			"https://example.org/a", "http://example.org/b",
			"file:///tmp/x.html", "about:blank", "javascript:alert(1)", "https:///nohost"
		]
		for text in cases {
			guard let url = URL(string: text) else { continue }
			XCTAssertEqual(
				FindingPageURL.storable(url) != nil,
				Finding.isValidPageURL(url),
				"disagreement on \(text)"
			)
		}
	}
}
