//
//  ScreenshotReportModifier.swift
//  AI Archeology
//
//  Offer to report a problem after the user screenshots one (AIA-0454).
//

import SwiftUI

/// Offers a support request right after the user takes a screenshot, so reporting a visual bug
/// does not require finding a Settings menu.
///
/// ## Why a screenshot is the trigger
///
/// The capture moment and the reporting moment are different moments. By the time a user reaches
/// Settings, the broken screen is gone — an app-side capture there would photograph the report
/// form, not the bug. So the app waits for the user to do what they would do anyway: screenshot
/// the thing that looks wrong.
///
/// **The app never captures the screen.** `userDidTakeScreenshotNotification` carries no image and
/// no `userInfo`; it only says that iOS took one, because the user pressed the buttons. The image
/// lands in the user's Photos, and reaches an email only if they pick it themselves.
///
/// ## Why the offer is shown once per install
///
/// This is a browser. People screenshot pages constantly for entirely ordinary reasons — saving an
/// article, sharing a paragraph — so an offer on every screenshot would be ambient nagging that
/// trains users to dismiss it. The state is persisted (not per-session) precisely because a
/// per-session throttle resets on every launch and would nag forever.
///
/// The cost of that choice: reporting in context works for the *first* screenshot only. Settings →
/// About → Report a problem remains the durable path, which is why the offer's job is as much to
/// teach that the feature exists as to file this particular report.
struct ScreenshotReportModifier: ViewModifier {
	@ObservedObject var settings: Settings
	@ObservedObject var featureFlags: FeatureFlagsState

	/// Supplies the web address involved, if the caller knows one. A closure, not a value, so this
	/// modifier does not have to observe the browser and re-render on every navigation.
	let currentURL: () -> String?

	@State private var showOffer = false
	@State private var showRequest = false

	func body(content: Content) -> some View {
		content
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
				offerReportIfAppropriate()
			}
			.alert(L10n.Support.Prompt.title, isPresented: $showOffer) {
				Button(L10n.Support.Prompt.report) { showRequest = true }
				Button(L10n.Support.Prompt.dontAskAgain, role: .destructive) {
					settings.supportPromptDeclined = true
				}
				Button(L10n.Common.cancel, role: .cancel) {}
			} message: {
				Text(L10n.Support.Prompt.message)
			}
			.sheet(isPresented: $showRequest) {
				SupportRequestView(initialCategory: .bug, contextURL: currentURL())
			}
	}

	private func offerReportIfAppropriate() {
		guard featureFlags.snapshot.isSupportReportingEnabled else { return }
		guard settings.supportPromptDeclined == false else { return }
		guard settings.supportPromptShown == false else { return }
		// Set before presenting, not in the alert's dismissal: every route out of this alert —
		// report, decline, cancel, or a system dismissal we never hear about — must consume the
		// one offer. Recording it only on an explicit answer would let a swipe-away re-arm it.
		settings.supportPromptShown = true
		LoggingPolicy.info("Screenshot detected — offering a support report (once per install).", logger: .ui)
		showOffer = true
	}
}

extension View {
	/// Offers a support request after a screenshot. See ``ScreenshotReportModifier``.
	func screenshotReportOffer(
		settings: Settings,
		featureFlags: FeatureFlagsState,
		currentURL: @escaping () -> String? = { nil }
	) -> some View {
		modifier(ScreenshotReportModifier(settings: settings, featureFlags: featureFlags, currentURL: currentURL))
	}
}
