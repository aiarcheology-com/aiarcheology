//
//  WelcomeView.swift
//  AI Archeology
//
//  The day-0 welcome screen (AIA-0567). Shown once, while the app-managed free-access
//  window is open, in place of the paywall that used to carry the same message.
//

import SwiftUI
import StoreKit

/// The zero-pressure screen a new user meets on day 0, while the free-access window
/// (AIA-0556) is still open.
///
/// AIA-0567 split the one screen that tried to be both an offer and a purchase form in two.
/// This is the half that is **not** a purchase screen, and the omissions are the design: no
/// Subscribe, no Restore, no renewal disclosure and no Terms/Privacy links. Those exist to
/// satisfy App Review 3.1.2 on a screen that takes money, and nothing here does — putting them
/// on a screen with no purchase control turns "you owe nothing today" into a page of billing
/// terms, which is the contradiction the split removes. When the window runs out,
/// ``PaywallView`` states all of it.
///
/// The price is still named, because "free for now" is only honest alongside what comes after.
/// It is named the way the store names it — never a literal — and vanishes into
/// ``L10n/Welcome/priceNoteGeneric`` when no product resolves, rather than guessing.
///
/// Deliberately dependency-light: a ``SubscriptionState`` for the price, the granted length, and
/// one way out. No `AuthState` and no `FindingRepository`, because unlike the hard wall this
/// screen is not a dead end — the whole app is one tap away, and with it every control those
/// would provide.
struct WelcomeView: View {
	@ObservedObject var subscriptionState: SubscriptionState
	@Environment(\.colorScheme) private var colorScheme

	/// The whole length of the free-access window being granted, in days.
	///
	/// Passed in rather than read here: the grant is remote-configurable and this view has no
	/// business resolving it. Rendered through a **pluralized** string — the value is floored at 1
	/// (`FreeAccessWindow`), so a flat format would put "free for 1 days" on the first screen a
	/// new user sees.
	let days: Int

	/// What to do when the user takes the offer and enters the app. The screen's only action.
	let continueAction: () -> Void

	var body: some View {
		GeometryReader { geometry in
			ScrollView {
				VStack(spacing: 24) {
					Spacer(minLength: 0)

					Image("AppLogo")
						.resizable()
						.scaledToFit()
						.frame(maxWidth: 120, maxHeight: 120)
						.accessibilityHidden(true)

					VStack(spacing: 8) {
						Text(L10n.Welcome.title)
							.font(.title).bold()
							.multilineTextAlignment(.center)
							// Wrap rather than truncate. English fits on one line, but "Willkommen
							// bei ML Browser" does not and rendered as "Willkommen bei ML Bro…" on
							// the first screen a new user sees (AIA-0572). The body below already
							// does this; the title and headline were missing it.
							.fixedSize(horizontal: false, vertical: true)

						Text(L10n.Welcome.headline(days))
							.font(.headline)
							.multilineTextAlignment(.center)
							.fixedSize(horizontal: false, vertical: true)
							.testability(Testability.Label.welcomeHeadline)

						Text(L10n.Welcome.body)
							.font(.body)
							.foregroundStyle(secondaryTextColor)
							.multilineTextAlignment(.center)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding(.horizontal, 32)

					Spacer(minLength: 0)

					content
						.padding(.horizontal, 32)
						.padding(.bottom, 24)
				}
				// Same contract as PaywallView (AIA-0564): the minimum height lets the two spacers
				// centre a short screen, and anything taller — landscape, large Dynamic Type — grows
				// past the viewport so the ScrollView exposes the price note and the footer instead
				// of clipping them.
				.frame(maxWidth: 480)
				.frame(maxWidth: .infinity, minHeight: geometry.size.height)
			}
			.testability(Testability.View.welcomeContent)
		}
		.background(WelcomeBackground())
		.task {
			// Kept off the launch path exactly as the paywall keeps it: a slow App Store fetch may
			// delay the price note, never app readiness. Until it answers, the generic sentence
			// stands — it is true either way.
			await subscriptionState.loadProducts()
		}
	}

	@ViewBuilder
	private var content: some View {
		// The one action. Full width and `.large` like Subscribe on the sibling screen, because
		// this is not a way out of a screen the user is being held on — it is the screen's purpose.
		// The tint is the shared `ContinueButton` colorset, which carries its own dark appearance
		// (the app hardcodes no colours).
		Button(action: continueAction) {
			Text(L10n.Welcome.continueButton)
				.fontWeight(.bold)
				.frame(maxWidth: .infinity)
		}
		.buttonStyle(.borderedProminent)
		.tint(Color(Self.continueButtonColorName, bundle: .main))
		.controlSize(.large)
		.testability(Testability.Button.welcomeContinue)

		priceNote

		// What the offer costs the user right now, stated three ways because "free" is the claim
		// people trust least. Small and secondary so they read as reassurance under the action
		// rather than as terms; allowed to claim their full height so a long translation or large
		// Dynamic Type wraps instead of truncating the word `No` off "No payment today".
		VStack(spacing: 6) {
			footerBullet(L10n.Welcome.Footer.noPayment)
			footerBullet(L10n.Welcome.Footer.noCard)
			footerBullet(L10n.Welcome.Footer.askLater)
		}
	}

	/// What a subscription will cost once the window closes — from the store, or not at all.
	///
	/// The generic fallback is not a degraded state to apologize for: App Store Connect being
	/// unreachable, unconfigured, or mocked all end here, and every one of them makes a stated
	/// price a guess. The sentence simply drops the amount and stays true.
	@ViewBuilder
	private var priceNote: some View {
		if let product = subscriptionState.products.first {
			Text(L10n.Welcome.priceNote(product.localizedPriceWithTerm))
				.font(.footnote)
				.foregroundStyle(secondaryTextColor)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
				// Any sentence embedding the price needs the spoken variant, or VoiceOver reads
				// "subscribe for $3.99 slash month" — see PaywallView, where the same pairing is
				// documented on the price itself.
				.accessibilityLabel(L10n.Welcome.priceNote(product.spokenPriceWithTerm))
		} else {
			Text(L10n.Welcome.priceNoteGeneric)
				.font(.footnote)
				.foregroundStyle(secondaryTextColor)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func footerBullet(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(secondaryTextColor)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
	}

	/// The `Assets.xcassets` colorset backing Continue — the same one ``PaywallView`` names, so the
	/// action keeps one identity across both screens of the split.
	private static let continueButtonColorName = "ContinueButton"

	/// The Light backdrop needs stronger contrast for explanatory copy, while Dark keeps the prior
	/// secondary style.
	private var secondaryTextColor: Color {
		colorScheme == .light ? Color(uiColor: .label).opacity(0.72) : .secondary
	}
}

/// The decorative layer behind the day-0 Welcome screen.
///
/// The collage is deliberately one pre-composed image: the factory and traffic scenes overlap in
/// the asset itself, so every aspect-fill crop reads as labeling rather than two adjacent photos.
/// It stays out of VoiceOver and never handles touches. The foreground `ScrollView` above remains
/// safe-area-aware while this layer alone reaches the display edges.
private struct WelcomeBackground: View {
	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		GeometryReader { geometry in
			ZStack {
				Color(uiColor: .systemBackground)

				if !reduceTransparency {
					Image(Self.imageName)
						.resizable()
						.interpolation(.high)
						.scaledToFill()
						.frame(width: geometry.size.width, height: geometry.size.height)
						// Preserve the collage's aspect ratio while shifting the rendered image upper-left.
						.scaleEffect(1.13, anchor: .bottomTrailing)
						.clipped()
						.opacity(imageOpacity)

					// Use fixed unit points, not semantic leading/trailing points: the visual requirement
					// is always top-left (0.0) to bottom-right (0.7), including right-to-left layouts.
					LinearGradient(
						colors: [
							Color(uiColor: .systemBackground).opacity(0),
							Color(uiColor: .systemBackground).opacity(0.7)
						],
						startPoint: UnitPoint(x: 0, y: 0),
						endPoint: UnitPoint(x: 1, y: 1)
					)
					.frame(width: geometry.size.width, height: geometry.size.height)
				}
			}
			.frame(width: geometry.size.width, height: geometry.size.height)
			.clipped()
		}
		.ignoresSafeArea()
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	/// Light appearance keeps the photo quieter against its light adaptive base; dark gets a
	/// slightly stronger image so the collage remains present. The required diagonal gradient is
	/// fixed independently at 0.0 to 0.7 in both appearances.
	private var imageOpacity: Double {
		colorScheme == .dark ? 0.34 : 0.30
	}

	private static let imageName = "WelcomeBackground"
}

#if DEBUG
#Preview("Welcome — 14 days") {
	WelcomeView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		days: 14,
		continueAction: {}
	)
}

/// The floor case. Proves the headline pluralizes rather than reading "free for 1 days".
#Preview("Welcome — 1 day") {
	WelcomeView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		days: 1,
		continueAction: {}
	)
}
#endif
