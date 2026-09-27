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

	func test_presentAccount_whileAnonymous_presentsSignIn() {
		for usesRealAuth in [true, false] {
			let presentation = DrawerPresentation()

			presentation.presentAccount(for: .anonymous, usesRealAuth: usesRealAuth)

			XCTAssertTrue(presentation.isSignInPresented)
			XCTAssertNil(presentation.settings)
			XCTAssertFalse(presentation.isFindingsPresented)
		}
	}

	func test_presentAccount_onceValidated_onRealAuth_presentsManageAccount() {
		let presentation = DrawerPresentation()

		presentation.presentAccount(for: .validated("account"), usesRealAuth: true)

		XCTAssertEqual(presentation.settings, .manageAccount)
		XCTAssertFalse(presentation.isSignInPresented)
	}

	/// Mock auth has no configured Clerk instance, which the Manage Account destination reads.
	func test_presentAccount_onceValidated_onMockAuth_presentsPlainSettings() {
		let presentation = DrawerPresentation()

		presentation.presentAccount(for: .validated("account"), usesRealAuth: false)

		XCTAssertEqual(presentation.settings, .settings)
		XCTAssertFalse(presentation.isSignInPresented)
	}

	/// The footer offers nothing to tap while auth is resolving or offline.
	func test_presentAccount_whileSuspendedOrIndeterminate_presentsNothing() {
		let contexts: [EffectiveAuthContext] = [.suspended(nil), .suspended("account"), .indeterminate]
		for context in contexts {
			for usesRealAuth in [true, false] {
				let presentation = DrawerPresentation()

				presentation.presentAccount(for: context, usesRealAuth: usesRealAuth)

				XCTAssertFalse(presentation.isAccountPresented, "\(context)")
				XCTAssertFalse(presentation.isSignInPresented, "\(context)")
				XCTAssertNil(presentation.settings, "\(context)")
			}
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
