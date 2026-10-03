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
/// ## How the offer is remembered
///
/// This is a browser. People screenshot pages constantly for entirely ordinary reasons — saving an
/// article, sharing a paragraph — so the app asks once before it starts offering a report after
/// every screenshot. Choosing **Report a problem** enables later offers; choosing **Don't ask
/// again** disables them. The user can change the same choice in Settings.
///
/// Cancelling is not an answer: the preference stays unset and the next screenshot asks again.
/// The offer decision, extracted so the guard order is a pure function the unit tests can pin
/// down — it lives inside a `ViewModifier` otherwise, where nothing can exercise it.
enum ScreenshotReportGate {
	/// The remote flag remains the master switch. An absent local choice asks the user, `true`
	/// keeps screenshot detection on, and only an explicit `false` suppresses the offer.
	static func shouldOffer(flagEnabled: Bool, screenshotDetectionEnabled: Bool?) -> Bool {
		flagEnabled && screenshotDetectionEnabled != false
	}
}

struct ScreenshotReportModifier: ViewModifier {
	@ObservedObject var settings: Settings
	@ObservedObject var featureFlags: FeatureFlagsState

	/// Whether Clerk is the real composition root. Passed through to the request sheet because
	/// this modifier sits at the very top of the scene — *outside* the tree's
	/// `.environment(\.usesRealAuth)` injection — so its presented sheet would otherwise read
	/// the key's default (`false`) and silently drop the account ID from every report.
	let usesRealAuth: Bool

	/// The launch-captured payments flag, passed explicitly for the same reason `usesRealAuth` is:
	/// this modifier sits above the gates that carry `SubscriptionState` (AIA-0955).
	let isPaymentsSurfaceEnabled: Bool

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
				Button(L10n.Support.Prompt.report) {
					settings.screenshotDetectionEnabled = true
					showRequest = true
				}
				Button(L10n.Support.Prompt.dontAskAgain, role: .destructive) {
					settings.screenshotDetectionEnabled = false
				}
				Button(L10n.Common.cancel, role: .cancel) {}
			} message: {
				Text(L10n.Support.Prompt.message)
			}
			.sheet(isPresented: $showRequest) {
				SupportRequestView(
					initialCategory: .bug,
					contextURL: currentURL(),
					isPaymentsSurfaceEnabled: isPaymentsSurfaceEnabled
				)
					// Re-injected per the key's own contract: it does not reliably cross `.sheet`
					// boundaries (see `UsesRealAuthKey`), and this sheet hangs off the scene root.
					.environment(\.usesRealAuth, usesRealAuth)
			}
	}

	private func offerReportIfAppropriate() {
		guard showOffer == false, showRequest == false else { return }
		guard ScreenshotReportGate.shouldOffer(
			flagEnabled: featureFlags.snapshot.isSupportReportingEnabled,
			screenshotDetectionEnabled: settings.screenshotDetectionEnabled
		) else { return }
		LoggingPolicy.info("Screenshot detected — offering a support report.", logger: .ui)
		showOffer = true
	}
}

extension View {
	/// Offers a support request after a screenshot. See ``ScreenshotReportModifier``.
	func screenshotReportOffer(
		settings: Settings,
		featureFlags: FeatureFlagsState,
		usesRealAuth: Bool,
		isPaymentsSurfaceEnabled: Bool,
		currentURL: @escaping () -> String? = { nil }
	) -> some View {
		modifier(ScreenshotReportModifier(
			settings: settings,
			featureFlags: featureFlags,
			usesRealAuth: usesRealAuth,
			isPaymentsSurfaceEnabled: isPaymentsSurfaceEnabled,
			currentURL: currentURL
		))
	}
}
