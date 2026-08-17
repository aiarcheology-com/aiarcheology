//
//  SharedFindingStateTests.swift
//  MLBrowserUnitTests
//
//  Buffering for shared finding links (AIA-0650).
//

import XCTest
@testable import ML_Browser

@MainActor
final class SharedFindingStateTests: XCTestCase {

	private func url(_ raw: String) throws -> URL {
		try XCTUnwrap(URL(string: raw))
	}

	private var validLink: String {
		"https://link.aiarcheology.com/f#v=1&t=Roman%20wall&c=stone_wall&p=87"
	}

	// MARK: - Accepting our own links

	func test_handle_buffersAFindingLink() throws {
		let sut = SharedFindingState()
		XCTAssertTrue(sut.handle(try url(validLink)))
		XCTAssertEqual(sut.pending?.title, "Roman wall")
		XCTAssertEqual(sut.pending?.confidencePercent, 87)
	}

	func test_handle_acceptsTheCustomSchemeForm() throws {
		let sut = SharedFindingState()
		XCTAssertTrue(sut.handle(try url("com.aiarcheology.ios://f#v=1&t=Villa")))
		XCTAssertEqual(sut.pending?.title, "Villa")
	}

	// MARK: - Leaving everyone else's URLs alone

	/// The app registers `com.aiarcheology.ios` for Clerk's OAuth callback, and this is the app's
	/// only `onOpenURL`. Swallowing one of these would break sign-in with no visible cause.
	func test_handle_ignoresClerkCallbacksAndOtherForeignURLs() throws {
		let sut = SharedFindingState()
		for raw in [
			"com.aiarcheology.ios://sso-callback?code=abc",
			"com.aiarcheology.ios://oauth/callback#access_token=xyz",
			"https://clerk.aiarcheology.com/v1/oauth_callback",
			"https://aiarcheology.com/f#v=1&t=X",
			"https://link.aiarcheology.com/other#v=1&t=X",
			"https://evil.example/f#v=1&t=X"
		] {
			XCTAssertFalse(sut.handle(try url(raw)), "\(raw) must not be consumed")
			XCTAssertNil(sut.pending, "\(raw) must not buffer anything")
		}
	}

	/// A foreign URL arriving while a link is pending must not disturb it — sign-in can happen
	/// while a shared finding is waiting behind the paywall.
	func test_handle_foreignURLDoesNotClearAPendingFinding() throws {
		let sut = SharedFindingState()
		sut.handle(try url(validLink))
		XCTAssertFalse(sut.handle(try url("com.aiarcheology.ios://sso-callback?code=abc")))
		XCTAssertEqual(sut.pending?.title, "Roman wall")
	}

	func test_handle_malformedFindingLinkIsNotConsumed() throws {
		let sut = SharedFindingState()
		for raw in [
			"https://link.aiarcheology.com/f",
			"https://link.aiarcheology.com/f#v=2&t=X",
			"https://link.aiarcheology.com/f#v=1&t=A&t=B"
		] {
			XCTAssertFalse(sut.handle(try url(raw)), "\(raw) must not be consumed")
			XCTAssertNil(sut.pending)
		}
	}

	// MARK: - Lifetime

	/// Newest wins. Two links in quick succession is someone tapping again, not a queue.
	func test_handle_aNewerLinkReplacesTheBufferedOne() throws {
		let sut = SharedFindingState()
		sut.handle(try url(validLink))
		sut.handle(try url("https://link.aiarcheology.com/f#v=1&t=Aqueduct"))
		XCTAssertEqual(sut.pending?.title, "Aqueduct")
	}

	func test_dismiss_clearsThePendingFinding() throws {
		let sut = SharedFindingState()
		sut.handle(try url(validLink))
		sut.dismiss()
		XCTAssertNil(sut.pending)
	}

	func test_dismiss_withNothingPendingIsHarmless() {
		let sut = SharedFindingState()
		sut.dismiss()
		XCTAssertNil(sut.pending)
	}

	/// The behaviour this type exists for, and the reason it does not copy
	/// `MessageCenterState`'s notification-tap buffer: that one arms a timeout and drops the
	/// buffered id once a snapshot arrives without it. A link tapped by someone who then spends
	/// several minutes behind the paywall must still be there when they get through.
	///
	/// Written as a mutation test rather than a timing one: nothing but `dismiss` or a replacement
	/// may clear `pending`, so exercising every other entry point must leave it standing.
	func test_pendingSurvivesEverythingExceptDismissalAndReplacement() throws {
		let sut = SharedFindingState()
		sut.handle(try url(validLink))

		// Every other way the outside world can touch this object.
		_ = sut.handle(try url("com.aiarcheology.ios://sso-callback?code=abc"))
		_ = sut.handle(try url("https://evil.example/f#v=1&t=X"))
		_ = sut.handle(try url("https://link.aiarcheology.com/f#v=1&t=A&t=B"))
		_ = sut.pending

		XCTAssertEqual(sut.pending?.title, "Roman wall", "only dismissal or a newer link may clear this")
	}

	// MARK: - Payload fidelity

	func test_handle_carriesEveryFieldThroughToPending() throws {
		let sut = SharedFindingState()
		let raw = "https://link.aiarcheology.com/f#v=1"
			+ "&i=3F2504E0-4F89-11D3-9A0C-0305E82C3301"
			+ "&t=Roman%20wall&c=stone_wall&p=87&g=48.80000,19.53000"
			+ "&u=https%3A%2F%2Fexample.org%2Fruins&a=V.%20Slav%C3%ADk&d=2026-08-17"
		XCTAssertTrue(sut.handle(try url(raw)))

		let pending = try XCTUnwrap(sut.pending)
		XCTAssertEqual(pending.id, UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
		XCTAssertEqual(pending.title, "Roman wall")
		XCTAssertEqual(pending.detectionClass, "stone_wall")
		XCTAssertEqual(pending.confidencePercent, 87)
		XCTAssertEqual(pending.coordinate?.latitude ?? 0, 48.8, accuracy: 0.00001)
		XCTAssertEqual(pending.coordinate?.longitude ?? 0, 19.53, accuracy: 0.00001)
		XCTAssertEqual(pending.page?.absoluteString, "https://example.org/ruins")
		XCTAssertEqual(pending.author, "V. Slavík")
		XCTAssertEqual(pending.date?.day, 17)
	}
}
