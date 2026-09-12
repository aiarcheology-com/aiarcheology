//
//  SharedFindingStateTests.swift
//  MLBrowserUnitTests
//
//  Buffering for shared finding links (AIA-0650).
//

import Combine
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
		XCTAssertEqual(sut.pending?.payload?.title, "Roman wall")
		XCTAssertEqual(sut.pending?.payload?.confidencePercent, 87)
	}

	func test_handle_acceptsTheCustomSchemeForm() throws {
		let sut = SharedFindingState()
		XCTAssertTrue(sut.handle(try url("com.aiarcheology.ios://f#v=1&t=Villa")))
		XCTAssertEqual(sut.pending?.payload?.title, "Villa")
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
		XCTAssertEqual(sut.pending?.payload?.title, "Roman wall")
	}

	/// A link that IS ours but will not parse must be **consumed** and marked unreadable, not
	/// silently dropped.
	///
	/// The association file matches on path alone, so iOS opens this app for any `/f` link — a
	/// truncated one, a hand-edited one, a `v=2` one from a future release. The landing page has copy
	/// for exactly that, and the landing page is what having the app installed prevents the user from
	/// seeing. If `handle` returned false here the app would open and do nothing, which reads as the
	/// app being broken rather than the link being damaged.
	func test_handle_ourOwnLinkThatWillNotParseIsMarkedUnreadable() throws {
		for raw in [
			"https://link.aiarcheology.com/f",
			"https://link.aiarcheology.com/f#",
			"https://link.aiarcheology.com/f#v=2&t=X",
			"https://link.aiarcheology.com/f#v=1&t=A&t=B",
			"https://link.aiarcheology.com/f#v=1&t=",
			"com.aiarcheology.ios://f#v=1",
			// Truncated mid-fragment, the way a platform that shortens links leaves one. Cut before
			// the title, which is what actually happens: `t` comes after `v` and `i` in key order, so
			// a link chopped at a length limit loses the title and everything after it.
			// (A truncation that merely SHORTENS the title is not this case — "Roman wa" is a valid
			// title and must still open the finding. That distinction is the point of this list.)
			"https://link.aiarcheology.com/f#v=1&i=3F2504E0-4F89-11D3-9A0C-0305E82C3301"
		] {
			let sut = SharedFindingState()
			XCTAssertTrue(sut.handle(try url(raw)), "\(raw) is ours and must be consumed")
			XCTAssertEqual(sut.pending, .unreadable, "\(raw) must surface as unreadable")
		}
	}

	/// The counterpart to the list above: a link whose title was merely shortened is still a valid
	/// link and must open the finding, not the "could not be read" screen. Truncation only breaks a
	/// link when it removes something the contract requires.
	func test_handle_aShortenedTitleStillOpensTheFinding() throws {
		let sut = SharedFindingState()
		XCTAssertTrue(sut.handle(try url("https://link.aiarcheology.com/f#v=1&t=Roman%20wa")))
		XCTAssertEqual(sut.pending?.payload?.title, "Roman wa")
	}

	/// A cut that lands mid percent-escape also still opens the finding, which is worth pinning down
	/// because it is not obvious: Foundation does not reject `t=Roman%2`. It re-encodes the stray
	/// escape (`percentEncodedFragment` reports `%252`) and the value decodes to the literal text
	/// "Roman%2". So the title arrives slightly mangled rather than the link becoming unreadable —
	/// the better outcome of the two, and the reason this is asserted rather than assumed.
	func test_handle_aTitleCutMidEscapeStillOpensTheFinding() throws {
		let sut = SharedFindingState()
		XCTAssertTrue(sut.handle(try url("https://link.aiarcheology.com/f#v=1&t=Roman%2")))
		XCTAssertEqual(sut.pending?.payload?.title, "Roman%2")
	}

	/// The truncated case above must not be confused with a *foreign* URL, which stays untouched.
	func test_handle_distinguishesUnreadableFromForeign() throws {
		let sut = SharedFindingState()
		XCTAssertFalse(sut.handle(try url("com.aiarcheology.ios://sso-callback?code=abc")))
		XCTAssertNil(sut.pending)
		XCTAssertTrue(sut.handle(try url("https://link.aiarcheology.com/f#v=2&t=X")))
		XCTAssertEqual(sut.pending, .unreadable)
	}

	/// An oversized link is refused rather than parsed. The custom scheme is registered app-wide, so
	/// any app on the device can hand this one a URL, and the parse runs on the main actor.
	func test_handle_refusesAnOversizedLink() throws {
		let sut = SharedFindingState()
		let huge = "https://link.aiarcheology.com/f#v=1&t=" + String(repeating: "a", count: 5000)
		XCTAssertTrue(sut.handle(try url(huge)), "it is still ours")
		XCTAssertEqual(sut.pending, .unreadable, "but it must not be parsed")
	}

	// MARK: - Lifetime

	/// Newest wins. Two links in quick succession is someone tapping again, not a queue.
	func test_handle_aNewerLinkReplacesTheBufferedOne() throws {
		let sut = SharedFindingState()
		sut.handle(try url(validLink))
		sut.handle(try url("https://link.aiarcheology.com/f#v=1&t=Aqueduct"))
		XCTAssertEqual(sut.pending?.payload?.title, "Aqueduct")
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

		// Every other way the outside world can touch this object. Deliberately only URLs that are
		// NOT ours: a malformed link on our own host is a legitimate replacement now, because it
		// resolves to `.unreadable` rather than being discarded.
		_ = sut.handle(try url("com.aiarcheology.ios://sso-callback?code=abc"))
		_ = sut.handle(try url("https://evil.example/f#v=1&t=X"))
		_ = sut.handle(try url("https://aiarcheology.com/f#v=1&t=X"))
		_ = sut.handle(try url("https://link.aiarcheology.com/other#v=1&t=X"))
		_ = sut.pending

		XCTAssertEqual(sut.pending?.payload?.title, "Roman wall", "only dismissal or a newer link may clear this")
	}

	// MARK: - Payload fidelity

	func test_handle_carriesEveryFieldThroughToPending() throws {
		let sut = SharedFindingState()
		let raw = "https://link.aiarcheology.com/f#v=1"
			+ "&i=3F2504E0-4F89-11D3-9A0C-0305E82C3301"
			+ "&t=Roman%20wall&c=stone_wall&p=87&g=48.80000,19.53000"
			+ "&u=https%3A%2F%2Fexample.org%2Fruins&a=V.%20Slav%C3%ADk&d=2026-08-17"
		XCTAssertTrue(sut.handle(try url(raw)))

		let pending = try XCTUnwrap(sut.pending?.payload)
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

	// MARK: - The page latch the shared screen hands its URL to (AIA-0657)

	/// `SharedFindingView.openPage` does not touch the web view directly — it latches
	/// `AppChromeState.pageToOpen`, which `WebScreen` drains. That indirection is what lets a link
	/// tapped behind the paywall land on its page after the gate resolves: `WebScreen` is not mounted
	/// yet, so nothing consumes the value until it is.
	///
	/// This pins the hazard on the *other* side of that route, which was live on `develop` before
	/// this ticket. `@Published` publishes from `willSet`, so a subscriber that clears the property
	/// inline is assigning *inside* the assignment that delivered the value — its store lands first
	/// and the outer store then writes the URL back over it. The latch stays armed and the next
	/// `WebScreen` to mount navigates away from whatever the user was reading.
	///
	/// **What this proves, and what it does not.** A SwiftUI `onReceive` closure is not reachable from
	/// a unit test, and `AppChromeState` takes four live dependencies to construct, so this exercises
	/// a stand-in with the same shape — one `@Published URL?` and a subscriber that clears it. It
	/// pins the *semantics* that force `WebScreen`'s deferred clear; that the real screen still uses
	/// that pattern is held by the comment there and by the agentic check on a running app.
	func test_clearingThePageLatchInlineDoesNotStick_butDeferringDoes() {
		/// The shape of `AppChromeState.pageToOpen` and nothing else.
		final class Latch: ObservableObject {
			@Published var pageToOpen: URL?
		}

		let chrome = Latch()
		let page = URL(string: "https://example.org/ruins")

		var inlineCancellable: AnyCancellable?
		inlineCancellable = chrome.$pageToOpen.sink { url in
			guard url != nil else { return }
			chrome.pageToOpen = nil
		}
		chrome.pageToOpen = page
		XCTAssertEqual(
			chrome.pageToOpen, page,
			"If this ever passes as nil, Combine's willSet semantics changed and WebScreen's deferred clear can be simplified"
		)
		inlineCancellable?.cancel()

		chrome.pageToOpen = nil
		var deferredCancellable: AnyCancellable?
		deferredCancellable = chrome.$pageToOpen.sink { url in
			guard url != nil else { return }
			DispatchQueue.main.async { chrome.pageToOpen = nil }
		}
		chrome.pageToOpen = page

		let drained = expectation(description: "the latch clears on the next runloop turn")
		DispatchQueue.main.async { drained.fulfill() }
		wait(for: [drained], timeout: 1)

		XCTAssertNil(chrome.pageToOpen, "the deferred clear is what WebScreen relies on")
		deferredCancellable?.cancel()
	}
}

/// Reaches the payload inside a `.finding` case. Tests assert on fields constantly; the enum is
/// there for the `.unreadable` distinction, not to make every assertion a `case let`.
private extension SharedFindingState.Pending {
	var payload: FindingShareLink.Payload? {
		if case .finding(let payload) = self { return payload }
		return nil
	}
}
