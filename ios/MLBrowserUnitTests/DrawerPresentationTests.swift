//
//  DrawerPresentationTests.swift
//  MLBrowserUnitTests
//
//  AIA-0984.
//

import XCTest
@testable import ML_Browser

/// The drawer's sheets, shared by the drawer view and headless mode. Closing them with the
/// drawer is `AppChromeState`'s job and is covered in `AppChromeStateTests`.
@MainActor
final class DrawerPresentationTests: XCTestCase {

	/// The footer's offer in each of the four auth contexts: the one rule the drawer footer draws and
	/// headless mode's `open-account` follows (AIA-1003).
	func test_accountOffer_coversEveryAuthContext() {
		XCTAssertEqual(DrawerPresentation.accountOffer(for: .anonymous), .signIn)
		XCTAssertEqual(DrawerPresentation.accountOffer(for: .validated("account")), .account)
		XCTAssertEqual(DrawerPresentation.accountOffer(for: .suspended("account")), .offline)
		XCTAssertEqual(DrawerPresentation.accountOffer(for: .suspended(nil)), .offline)
		XCTAssertNil(DrawerPresentation.accountOffer(for: .indeterminate))
	}

	func test_presentAccount_signIn_presentsSignIn() {
		for usesRealAuth in [true, false] {
			let presentation = DrawerPresentation()

			presentation.presentAccount(.signIn, usesRealAuth: usesRealAuth)

			XCTAssertTrue(presentation.isSignInPresented)
			XCTAssertNil(presentation.settings)
			XCTAssertFalse(presentation.isFindingsPresented)
		}
	}

	func test_presentAccount_account_onRealAuth_presentsManageAccount() {
		let presentation = DrawerPresentation()

		presentation.presentAccount(.account, usesRealAuth: true)

		XCTAssertEqual(presentation.settings, .manageAccount)
		XCTAssertFalse(presentation.isSignInPresented)
	}

	/// Mock auth has no configured Clerk instance, which the Manage Account destination reads.
	func test_presentAccount_account_onMockAuth_presentsPlainSettings() {
		let presentation = DrawerPresentation()

		presentation.presentAccount(.account, usesRealAuth: false)

		XCTAssertEqual(presentation.settings, .settings)
		XCTAssertFalse(presentation.isSignInPresented)
	}

	/// The offline card has nothing to tap; while auth is resolving there is no offer at all.
	func test_presentAccount_offline_presentsNothing() {
		for usesRealAuth in [true, false] {
			let presentation = DrawerPresentation()

			presentation.presentAccount(.offline, usesRealAuth: usesRealAuth)

			XCTAssertFalse(presentation.isAccountPresented)
			XCTAssertFalse(presentation.isSignInPresented)
			XCTAssertNil(presentation.settings)
		}
	}

	func test_isAccountPresented_isSignInOrSettings() {
		let presentation = DrawerPresentation()
		XCTAssertFalse(presentation.isAccountPresented)

		presentation.isFindingsPresented = true
		XCTAssertFalse(presentation.isAccountPresented, "the findings list is not the account screen")

		presentation.isSignInPresented = true
		XCTAssertTrue(presentation.isAccountPresented)

		presentation.isSignInPresented = false
		presentation.settings = .settings
		XCTAssertTrue(presentation.isAccountPresented)

		presentation.settings = .manageAccount
		XCTAssertTrue(presentation.isAccountPresented)
	}

	/// The headless account screen's `close`, `sign-in` and `sign-out` close the account screen only.
	func test_dismissAccount_leavesTheFindingsList() {
		let presentation = DrawerPresentation()
		presentation.isFindingsPresented = true
		presentation.isSignInPresented = true
		presentation.settings = .manageAccount

		presentation.dismissAccount()

		XCTAssertFalse(presentation.isAccountPresented)
		XCTAssertTrue(presentation.isFindingsPresented)
	}

	func test_dismissSheets_closesEverySheet() {
		let presentation = DrawerPresentation()
		presentation.isFindingsPresented = true
		presentation.isSignInPresented = true
		presentation.settings = .settings

		presentation.dismissSheets()

		XCTAssertFalse(presentation.isFindingsPresented)
		XCTAssertFalse(presentation.isSignInPresented)
		XCTAssertNil(presentation.settings)
	}
}
