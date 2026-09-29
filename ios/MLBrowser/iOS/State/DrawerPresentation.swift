//
//  DrawerPresentation.swift
//  AI Archeology
//
//  AIA-0984.
//

import Observation

/// Which Settings screen the drawer presents: plain Settings, or seeded at Manage Account.
enum SettingsPresentation: Hashable, Identifiable {
	case settings
	case manageAccount

	var id: Self { self }

	var startsAtManageAccount: Bool {
		self == .manageAccount
	}
}

/// The drawer footer's row: Sign In, the signed-in account, or the account shown as offline.
enum AccountOffer { case signIn, account, offline }

/// The sheets the drawer presents: the findings list, the sign-in sheet and Settings.
///
/// One model shared by the SwiftUI drawer, which binds its `.sheet`s to it, and headless mode,
/// which reports and drives the same flags (AIA-0984). It used to be `@State` in `DrawerContent`,
/// with a headless copy beside it; one owner means the two builds cannot drift.
///
/// Owned app-wide by `AppChromeState` rather than per view: the app has a single window
/// (`UIApplicationSupportsMultipleScenes = false`), so one instance matches the per-view state it
/// replaces. The drawer's view is unmounted while the drawer is closed, which used to drop that
/// state; `AppChromeState` now dismisses these sheets whenever the drawer closes, for the same end
/// state.
///
/// The flags are independent, as the three `@State`s were: presenting one does not clear the
/// others. The drawer's rows sit under whichever sheet is up, so only one is opened at a time.
@MainActor
@Observable
final class DrawerPresentation {
	/// The drawer's Findings row: the findings list.
	var isFindingsPresented = false
	/// The footer's Sign In row while anonymous: `SignInSheet`.
	var isSignInPresented = false
	/// The Settings row, or the footer's account row once signed in.
	var settings: SettingsPresentation?

	/// The account screen is up: the sign-in sheet or Settings. What the headless `account` route
	/// means — Settings is where a signed-in account signs out and manages its findings.
	var isAccountPresented: Bool {
		isSignInPresented || settings != nil
	}

	/// What the drawer footer offers in each auth context — the one rule the footer draws and
	/// headless mode's `open-account` follows (AIA-1003). `offline` is shown but not tappable: sign-in
	/// would fail with no network, and Clerk cannot render the profile. `nil` while auth is resolving.
	static func accountOffer(for context: EffectiveAuthContext) -> AccountOffer? {
		switch context {
		case .anonymous: .signIn
		case .validated: .account
		case .suspended: .offline
		case .indeterminate: nil
		}
	}

	/// The drawer footer's tap: sign in while anonymous; once validated, Settings — seeded at Manage
	/// Account on real auth only, because that destination reads `Clerk.shared`, which traps when
	/// Clerk was never configured. The offline offer has nothing to tap and presents nothing.
	func presentAccount(_ offer: AccountOffer, usesRealAuth: Bool) {
		switch offer {
		case .signIn: isSignInPresented = true
		case .account: settings = usesRealAuth ? .manageAccount : .settings
		case .offline: break
		}
	}

	/// Closes the account screen, whichever of the two is up, and leaves the findings list alone.
	func dismissAccount() {
		isSignInPresented = false
		settings = nil
	}

	/// Closes every drawer sheet: the drawer is closing, and none of them shows without it.
	func dismissSheets() {
		isFindingsPresented = false
		isSignInPresented = false
		settings = nil
	}
}
