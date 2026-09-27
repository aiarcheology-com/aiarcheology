//
//  SaveFindingPresentation.swift
//  AI Archeology
//
//  AIA-0984.
//

import Observation

/// The save-finding sheet's presentation: the picked detection it shows, and the one-time sign-in
/// offer that may follow a save.
///
/// One model shared by the web screen, which binds its save sheet and its sign-in offer to it, and the
/// headless build, which reports and drives the same state (AIA-0984). Both used to be `@State` in
/// `WebScreenView`, with a headless copy of the capture in `StagedImageCapture`; one owner means the
/// two builds cannot drift.
///
/// Owned app-wide by `AppChromeState` rather than per view: the app has a single window
/// (`UIApplicationSupportsMultipleScenes = false`) and one web screen, so one instance matches the
/// per-view state it replaces. The web screen clears it in its `onDisappear`, where the `@State`
/// used to be dropped with the view.
@MainActor
@Observable
final class SaveFindingPresentation {
	/// The picked detection being saved. Non-nil means the save sheet is up.
	var capture: FindingCapture?

	/// The one-time contextual sign-in offer that follows a save (AIA-0536): `SignInSheet`, presented
	/// by the web screen.
	var isSignInOfferPresented = false

	/// Whether the save sheet is up.
	var isPresented: Bool {
		capture != nil
	}

	/// Offer sign-in once, after a save, to someone who could actually act on it.
	///
	/// Deliberately narrow. The offer is a convenience, not a gate: the save already succeeded and
	/// nothing about it depends on an account. So it is skipped during onboarding, for anyone not
	/// plainly signed out, and after it has been shown once — with the marker set here, at the moment
	/// of showing, so a save that produced no offer never spends the single chance to ask.
	func offerSignInIfEarned(authContext: EffectiveAuthContext, isTourActive: Bool, settings: Settings) {
		guard case .anonymous = authContext else { return }
		guard !isTourActive else { return }
		guard !settings.signInOfferShown else { return }
		settings.signInOfferShown = true
		isSignInOfferPresented = true
	}

	/// Closes the sign-in offer.
	func dismissSignInOffer() {
		isSignInOfferPresented = false
	}
}
