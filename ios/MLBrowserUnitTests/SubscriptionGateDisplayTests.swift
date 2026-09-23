//
//  SubscriptionGateDisplayTests.swift
//  AI ArcheologyTests
//
//  The root gate's precedence rule: payments surface, then entitlement, then the free window
//  (AIA-0556).
//

import XCTest
@testable import ML_Browser

final class SubscriptionGateDisplayTests: XCTestCase {

	private func resolve(
		paymentsSurface: Bool = true,
		subscribed: Bool = false,
		freeAccess: FreeAccessAvailability,
		hasEverShownContent: Bool = false
	) -> RootGateDisplay {
		RootGateDisplay.resolve(
			isPaymentsSurfaceEnabled: paymentsSurface,
			isSubscribed: subscribed,
			freeAccess: freeAccess,
			hasEverShownContent: hasEverShownContent
		)
	}

	// MARK: - Entitlement precedence

	/// **The one that costs a paying customer.** A user who taps Subscribe on day 13 starts Apple's
	/// trial and is `isSubscribed`; on day 14 their app-managed window runs out. Walling them there
	/// bills someone for a paywall. Entitlement outranks an expired window, always.
	func testTrialStartedOnDayThirteen_isNotWalledWhenTheFreeWindowExpiresOnDayFourteen() {
		// Cold launch: nothing shown yet, so the wall would be the arrival screen.
		XCTAssertEqual(resolve(subscribed: true, freeAccess: .closed), .content)

		// And mid-session, which is the likelier moment: the window runs out at midnight while the
		// user is reading a page. Not `.wallOverContent` — they are paying, so there is nothing to
		// cover. Previously this assertion re-ran the cold-launch case and proved nothing twice.
		XCTAssertEqual(
			resolve(subscribed: true, freeAccess: .closed, hasEverShownContent: true),
			.content
		)
	}

	func testSubscribed_withNoWindowEverGranted_showsContent() {
		XCTAssertEqual(resolve(subscribed: true, freeAccess: .closed), .content)
	}

	// MARK: - The three ways in

	func testPaymentsSurfaceDisabled_showsContentRegardlessOfEverythingElse() {
		for freeAccess: FreeAccessAvailability in [.undetermined, .open, .closed] {
			for shown in [true, false] {
				XCTAssertEqual(
					resolve(
						paymentsSurface: false,
						subscribed: false,
						freeAccess: freeAccess,
						hasEverShownContent: shown
					),
					.content,
					"A flag-off build is fully open (freeAccess: \(freeAccess), shown: \(shown))."
				)
			}
		}
	}

	func testNotEntitled_withAnOpenWindow_showsContent() {
		XCTAssertEqual(resolve(freeAccess: .open), .content)
	}

	func testNotEntitled_withAnExpiredWindow_showsTheWall() {
		XCTAssertEqual(resolve(freeAccess: .closed), .wall)
	}

	/// `develop`'s behaviour, preserved: with the free-access flag off nothing is ever granted, so
	/// availability settles `.closed` and a non-subscriber meets the paywall exactly as before.
	func testNotEntitled_withNoWindowEverGranted_showsTheWall() {
		XCTAssertEqual(resolve(freeAccess: .closed), .wall)
	}

	// MARK: - Reconciliation must not read as a refusal

	/// `FreeAccessWindow` reports "not granted" while its two stores are being read. Treating that
	/// as a wall would flash the paywall at a valid mid-window user on every single launch.
	func testFreeAccessUndetermined_holdsRatherThanWalling() {
		XCTAssertEqual(resolve(freeAccess: .undetermined), .hold)
		XCTAssertNotEqual(resolve(freeAccess: .undetermined), .wall)
	}

	/// Once the user is in the app, an unsettled anchor is not a reason to throw them out of it —
	/// nor to cover their page with a wall that may turn out to be wrong.
	func testFreeAccessUndetermined_afterContentWasShown_keepsContentUncovered() {
		XCTAssertEqual(resolve(freeAccess: .undetermined, hasEverShownContent: true), .content)
	}

	// MARK: - Expiry must not tear down the root

	/// The window running out mid-session covers the app; it does not replace it. Swapping the root
	/// destroys the `WKWebView` and with it the page, the scroll position and the history.
	func testWindowExpiringAfterContentWasShown_laysTheWallOverRetainedContent() {
		XCTAssertEqual(resolve(freeAccess: .closed, hasEverShownContent: true), .wallOverContent)
	}

	/// The same refusal is a full screen on the way *in*, where there is no session to protect and
	/// rendering the app behind the wall would load pages nobody is entitled to see.
	func testWindowClosedBeforeContentWasShown_makesTheWallTheArrivalScreen() {
		XCTAssertEqual(resolve(freeAccess: .closed, hasEverShownContent: false), .wall)
	}

	// MARK: - When the armed onboarding tour may start (AIA-0567)

	/// Every clause below closes a hole a review actually found. The failure modes are silent —
	/// a tour that never runs again, or one running underneath the screen meant to precede it —
	/// so none of them announces itself in manual testing.
	private func mayStart(
		isShowingContent: Bool = true,
		isWelcomeOnScreenHere: Bool = false,
		isWelcomeOnScreenAnywhere: Bool = false,
		isWelcomeDue: Bool = false,
		canPresentWelcome: Bool = true
	) -> Bool {
		TourStartDecision.mayStart(
			isShowingContent: isShowingContent,
			isWelcomeOnScreenHere: isWelcomeOnScreenHere,
			isWelcomeOnScreenAnywhere: isWelcomeOnScreenAnywhere,
			isWelcomeDue: isWelcomeDue,
			canPresentWelcome: canPresentWelcome
		)
	}

	/// The ordinary case: nothing is owed the screen, so onboarding gets it.
	func testTourStarts_whenNothingIsOwedTheScreen() {
		XCTAssertTrue(mayStart())
	}

	/// A wall is on screen, not the app. There is nothing to run a tour over.
	func testTourWaits_whileTheAppIsNotWhatIsShowing() {
		XCTAssertFalse(mayStart(isShowingContent: false))
	}

	/// The marker is written when the Welcome screen is *raised*, which clears the due flag at once
	/// — so the due flag alone would start the tour underneath a screen on the display right now.
	func testTourWaits_whileAWelcomeScreenIsUpInThisWindow() {
		XCTAssertFalse(mayStart(isWelcomeOnScreenHere: true, isWelcomeDue: false))
	}

	/// The same question across windows. `presentedPrompt` is scene-local while the tour is shared,
	/// so with two iPad windows the one that raised the Welcome screen is not the one that would
	/// otherwise start the tour underneath it.
	func testTourWaits_whileAWelcomeScreenIsUpInAnotherWindow() {
		XCTAssertFalse(mayStart(isWelcomeOnScreenAnywhere: true, isWelcomeDue: false))
	}

	/// A Welcome screen is owed and can still be raised, so the tour must not jump the queue.
	func testTourWaits_whenAWelcomeScreenIsStillOwedAndCanBeRaised() {
		XCTAssertFalse(mayStart(isWelcomeDue: true, canPresentWelcome: true))
	}

    /// The inverse edge, and the reason "owed" alone is not the condition: a subscriber whose window
	/// still owes an unshown day 0 can never have it raised. Blocking on owed-ness alone would leave
	/// their tour armed forever, and with it their analytics consent question deferred forever.
	func testTourStarts_whenAWelcomeIsOwedButCanNeverBeRaised() {
		XCTAssertTrue(mayStart(isWelcomeDue: true, canPresentWelcome: false))
	}

	/// The regression that made the fallback key off `display` rather than "a Welcome could show":
	/// a first launch that meets the wall and is then purchased past must still get its tour.
	func testTourStarts_afterAWalledUserBuysTheirWayIntoTheApp() {
		XCTAssertTrue(mayStart(isShowingContent: true, isWelcomeDue: false, canPresentWelcome: false))
	}

	// MARK: - Which Welcome screen (AIA-0955)

	private let prompt = FreeAccessPrompt(days: 14, endsOn: Date(timeIntervalSince1970: 1_800_000_000))

	/// Payments on: the window's offer, and never the payments-off introduction — a first run with
	/// payments on is introduced by the offer itself.
	func testWelcome_paymentsOn_isTheFreeAccessOffer() {
		XCTAssertEqual(
			WelcomePresentation.due(isPaymentsSurfaceEnabled: true, freeAccessPrompt: prompt, isIntroductionOwed: true),
			.freeAccess(prompt)
		)
		XCTAssertNil(
			WelcomePresentation.due(isPaymentsSurfaceEnabled: true, freeAccessPrompt: nil, isIntroductionOwed: true),
			"an owed introduction must not surface while payments are on"
		)
	}

	/// Payments off: the neutral introduction, and never the priced offer — even when a window
	/// persisted under payments on still owes one.
	func testWelcome_paymentsOff_isTheIntroduction_neverThePricedOffer() {
		XCTAssertEqual(
			WelcomePresentation.due(isPaymentsSurfaceEnabled: false, freeAccessPrompt: prompt, isIntroductionOwed: true),
			.introduction
		)
		XCTAssertNil(
			WelcomePresentation.due(isPaymentsSurfaceEnabled: false, freeAccessPrompt: prompt, isIntroductionOwed: false),
			"a payments-off session raised the priced day-0 offer"
		)
	}
}
