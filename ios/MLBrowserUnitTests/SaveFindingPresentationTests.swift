//
//  SaveFindingPresentationTests.swift
//  MLBrowserUnitTests
//
//  AIA-0984.
//

import XCTest
@testable import ML_Browser

/// The one-time sign-in offer after a save, decided once for the web screen and the headless build.
@MainActor
final class SaveFindingPresentationTests: XCTestCase {

	private var settings: Settings!
	/// `signInOfferShown` as the test found it: `Settings()` writes the shared defaults, and the marker
	/// survives `reset()`, so the test puts it back.
	private var markerBefore = false

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		markerBefore = settings.signInOfferShown
		settings.signInOfferShown = false
	}

	override func tearDown() async throws {
		settings.signInOfferShown = markerBefore
		settings = nil
		try await super.tearDown()
	}

	func test_aSignedOutSaveOutsideTheTour_offersSignIn_andSpendsTheMarker() {
		let presentation = SaveFindingPresentation()

		presentation.offerSignInIfEarned(authContext: .anonymous, isTourActive: false, settings: settings)

		XCTAssertTrue(presentation.isSignInOfferPresented)
		XCTAssertTrue(settings.signInOfferShown)
	}

	func test_theOffer_isShownOnce() {
		let first = SaveFindingPresentation()
		first.offerSignInIfEarned(authContext: .anonymous, isTourActive: false, settings: settings)
		XCTAssertTrue(first.isSignInOfferPresented)

		let second = SaveFindingPresentation()
		second.offerSignInIfEarned(authContext: .anonymous, isTourActive: false, settings: settings)

		XCTAssertFalse(second.isSignInOfferPresented, "the marker is already spent")
	}

	/// Anyone not plainly signed out gets no offer, and the single chance to ask is kept.
	func test_notSignedOut_offersNothing_andKeepsTheMarker() {
		let contexts: [EffectiveAuthContext] = [.indeterminate, .validated("account"), .suspended("account")]
		for context in contexts {
			let presentation = SaveFindingPresentation()

			presentation.offerSignInIfEarned(authContext: context, isTourActive: false, settings: settings)

			XCTAssertFalse(presentation.isSignInOfferPresented, "\(context)")
			XCTAssertFalse(settings.signInOfferShown, "\(context)")
		}
	}

	func test_duringTheTour_offersNothing_andKeepsTheMarker() {
		let presentation = SaveFindingPresentation()

		presentation.offerSignInIfEarned(authContext: .anonymous, isTourActive: true, settings: settings)

		XCTAssertFalse(presentation.isSignInOfferPresented)
		XCTAssertFalse(settings.signInOfferShown)
	}

	func test_anOfferAlreadyShown_offersNothing() {
		settings.signInOfferShown = true
		let presentation = SaveFindingPresentation()

		presentation.offerSignInIfEarned(authContext: .anonymous, isTourActive: false, settings: settings)

		XCTAssertFalse(presentation.isSignInOfferPresented)
		XCTAssertTrue(settings.signInOfferShown)
	}

	func test_dismissSignInOffer_closesTheOffer_andKeepsTheMarkerSpent() {
		let presentation = SaveFindingPresentation()
		presentation.offerSignInIfEarned(authContext: .anonymous, isTourActive: false, settings: settings)

		presentation.dismissSignInOffer()

		XCTAssertFalse(presentation.isSignInOfferPresented)
		XCTAssertTrue(settings.signInOfferShown, "closing the offer does not give the chance back")
	}
}
