//
//  PaywallView.swift
//  AI Archeology
//
//  Subscription paywall (AIA-0343). Lists the product(s), Subscribe, Restore, and a
//  manage-subscription link. Styled to match the auth screens.
//

import SwiftUI
import StoreKit
import OSLog

/// The paywall. Presented as the whole-app root gate (`SubscriptionGateView`) when the
/// A message the purchase/restore flow owes the user (AIA-0376).
///
/// Carries its own title because not every outcome is an error: Ask-to-Buy and
/// "nothing to restore" are ordinary answers and must not be dressed as failures.
struct SubscriptionNotice: Equatable, Identifiable {
	let id = UUID()
	let title: String
	let message: String

	/// What to say once a purchase attempt finishes. `nil` means stay quiet.
	///
	/// The two silent cases are the point of this type. `.subscribed` dismisses the paywall,
	/// so an alert would interrupt the success it is announcing; `.cancelled` is the user's
	/// own decision, and telling someone their purchase failed because they tapped Cancel is
	/// how you get a one-star review. Everything else was previously silent — which is the
	/// bug this fixes.
	static func forPurchase(_ outcome: PurchaseOutcome) -> SubscriptionNotice? {
		switch outcome {
		case .subscribed, .cancelled:
			return nil
		case .pending:
			return .init(title: L10n.Paywall.Pending.title, message: L10n.Paywall.Pending.message)
		case .failed:
			return .init(title: L10n.Alert.Error.title, message: L10n.Paywall.Failed.message)
		}
	}

	/// What to say once a restore attempt finishes. `nil` means stay quiet.
	///
	/// `.restored` needs no alert: the entitlement lands in published state and the gate
	/// re-renders, which is the answer. `.nothingToRestore` is **not** an error — the store
	/// answered correctly and the account owns nothing.
	static func forRestore(_ outcome: RestoreOutcome) -> SubscriptionNotice? {
		switch outcome {
		case .restored:
			return nil
		case .nothingToRestore:
			return .init(title: L10n.Paywall.RestoreEmpty.title, message: L10n.Paywall.RestoreEmpty.message)
		case .failed:
			return .init(title: L10n.Alert.Error.title, message: L10n.Paywall.RestoreFailed.message)
		}
	}
}

/// signed-in user isn't subscribed. Reads products and entitlement from
/// ``SubscriptionState`` and drives purchase / restore intents.
struct PaywallView: View {
	@ObservedObject var subscriptionState: SubscriptionState
	let analytics: AnalyticsState?

	/// Auth state, supplied only when the paywall is the whole-app root gate, so a
	/// non-subscriber can sign out or delete their account (Apple 5.1.1(v)). `nil` when
	/// presented from Settings (sign-out/delete live in the Clerk profile there).
	var authState: AuthState?

	/// True when this is the whole-app root gate (vs. the Settings sheet). Enables the
	/// sign-out / delete-account affordances.
	var isRootGate = false

	@Environment(\.dismiss) private var dismiss

	/// Disables the action buttons while a purchase/restore round-trip is in flight.
	@State private var isWorking = false

	/// Drives Apple's in-app refund request sheet for the active subscription.
	@State private var showRefund = false

	/// Presents the in-app Privacy Policy (App Review requires it on the purchase screen).
	@State private var showPrivacy = false

	/// Root-gate account actions (Apple 5.1.1(v)): confirm + report deletion failures.
	@State private var showDeleteConfirmation = false
	@State private var deleteFailed = false

	/// What to tell the user about the last purchase/restore attempt; `nil` while there is
	/// nothing to say (AIA-0376).
	@State private var notice: SubscriptionNotice?

	/// Whether *this user* is still eligible for the introductory free trial. A user who
	/// already used the trial is charged the full price immediately, so the "free for N"
	/// copy must only show when they'd actually get it (else it's misleading / an App
	/// Review risk). Resolved per-user from StoreKit on appear; defaults to `false` so we
	/// never over-promise a trial.
	@State private var introOfferEligible = false

	var body: some View {
		VStack(spacing: 24) {
			Spacer()

			Image("AppLogo")
				.resizable()
				.scaledToFit()
				.frame(maxWidth: 120, maxHeight: 120)
				.accessibilityHidden(true)

			VStack(spacing: 8) {
				Text(L10n.Paywall.title)
					.font(.title).bold()
					.multilineTextAlignment(.center)
				Text(L10n.Paywall.tagline)
					.font(.body)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
			.padding(.horizontal, 32)

			if subscriptionState.isSubscribed {
				Label(L10n.Paywall.active, systemImage: "checkmark.seal.fill")
					.foregroundStyle(.green)
					.font(.headline)
			}

			Spacer()

			content
				.padding(.horizontal, 32)
				.padding(.bottom, 24)
		}
		// Cap the content/buttons width so the paywall doesn't stretch edge-to-edge on
		// iPad; the outer frame then centers that block on the full screen.
		.frame(maxWidth: 480)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.task {
			// Load products when the paywall appears (kept off the launch path so a slow
			// App Store fetch never delays app readiness), then resolve this user's
			// intro-offer eligibility so the trial copy only shows when they'd get it.
			await subscriptionState.loadProducts()
			if let subscription = subscriptionState.products.first?.subscription {
				introOfferEligible = await subscription.isEligibleForIntroOffer
			}
		}
		.onAppear {
			analytics?.track(.paywallShown)
		}
		.confirmationDialog(
			L10n.Auth.Account.Delete.title,
			isPresented: $showDeleteConfirmation,
			titleVisibility: .visible
		) {
			Button(L10n.Auth.Account.Delete.action, role: .destructive) {
				Task {
					do {
						try await authState?.deleteAccount()
					} catch {
						LoggingPolicy.error("Account deletion failed: \(error.localizedDescription)", logger: .state)
						deleteFailed = true
					}
				}
			}
			Button(L10n.Common.cancel, role: .cancel) {}
		} message: {
			Text(L10n.Auth.Account.Delete.message)
		}
		.alert(L10n.Alert.Error.title, isPresented: $deleteFailed) {
			Button(L10n.Common.ok, role: .cancel) {}
		} message: {
			Text(L10n.Alert.Error.unexpected)
		}
		// Purchase/restore feedback (AIA-0376). Before this, every non-success outcome ended
		// with the spinner stopping and nothing else — the user stared at an unchanged paywall.
		.alert(notice?.title ?? L10n.Alert.Error.title, isPresented: .init(
			get: { notice != nil },
			set: { if !$0 { notice = nil } }
		)) {
			Button(L10n.Common.ok, role: .cancel) {}
		} message: {
			Text(notice?.message ?? "")
		}
	}

	@ViewBuilder
	private var content: some View {
		if let product = subscriptionState.products.first {
			productSection(product)
		} else {
			// Empty product list: App Store Connect not configured yet, the local
			// .storekit file isn't wired into the scheme, or the mock path. Degrade
			// gracefully rather than showing a dead Subscribe button.
			Text(L10n.Paywall.unavailable)
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}

		Button {
			Task {
				isWorking = true
				let outcome = await subscriptionState.restore()
				isWorking = false
				notice = SubscriptionNotice.forRestore(outcome)
			}
		} label: {
			Text(L10n.Paywall.restore)
				.frame(maxWidth: .infinity)
		}
		.buttonStyle(.bordered)
		.controlSize(.large)
		.disabled(isWorking)
		.testability(Testability.Button.paywallRestore)

		// Request a refund via Apple's native sheet — only for an active subscription
		// (Apple owns the decision; this just opens the request flow).
		if subscriptionState.isSubscribed, let transactionID = subscriptionState.currentTransactionID {
			Button(role: .destructive) {
				showRefund = true
			} label: {
				Text(L10n.Paywall.requestRefund).frame(maxWidth: .infinity)
			}
			.buttonStyle(.bordered)
			.controlSize(.large)
			.testability(Testability.Button.paywallRequestRefund)
			.refundRequestSheet(for: transactionID, isPresented: $showRefund)
		}

		// Manage existing subscription (cancel / change plan). Always available so a
		// subscriber can reach Apple's management screen from here.
		Link(L10n.Paywall.manage, destination: Self.manageSubscriptionsURL)
			.font(.footnote)
			.testability(Testability.Link.paywallManage)

		legalFooter

		// Whole-app root gate only: let a non-subscriber leave or delete their account
		// (they can't reach Settings from behind the gate). Apple 5.1.1(v).
		if isRootGate, let authState {
			VStack(spacing: 12) {
				Button {
					Task { await authState.signOut() }
				} label: {
					Text(L10n.Auth.signOut).frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
				.testability(Testability.Button.paywallSignOut)

				Button(role: .destructive) {
					showDeleteConfirmation = true
				} label: {
					Text(L10n.Auth.Account.Delete.action).frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			}
			.padding(.top, 8)
		}
	}

	/// Auto-renewable subscription disclosures required on the purchase screen
	/// (App Review Guideline 3.1.2): renewal terms + Terms of Use + Privacy Policy.
	@ViewBuilder
	private var legalFooter: some View {
		VStack(spacing: 8) {
			Text(L10n.Paywall.disclosure)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				// Required disclosure (App Review 3.1.2) must show in full — let it claim its
				// natural height so it wraps instead of truncating under vertical compression.
				.fixedSize(horizontal: false, vertical: true)

			HStack(spacing: 16) {
				Link(L10n.Paywall.terms, destination: Self.termsOfUseURL)
				Button(L10n.About.privacyPolicy) { showPrivacy = true }
			}
			.font(.caption2)
		}
		.padding(.top, 4)
		.sheet(isPresented: $showPrivacy) {
			NavigationStack {
				PrivacyPolicyView(htmlFileName: "privacypolicy")
					.navigationTitle(L10n.About.privacyPolicy)
					.navigationBarTitleDisplayMode(.inline)
					.toolbar {
						ToolbarItem(placement: .confirmationAction) {
							Button(L10n.Common.done) { showPrivacy = false }
						}
					}
			}
		}
	}

	@ViewBuilder
	private func productSection(_ product: Product) -> some View {
		VStack(spacing: 4) {
			Text(product.displayName)
				.font(.headline)
			Text(product.displayPrice)
				.font(.title2).bold()

			// Free-trial terms — only when *this user* is still eligible (a returning user
			// who already used the trial is charged immediately, so showing "free for N"
			// would be misleading). Length/price come from the product (set in ASC).
			if introOfferEligible, let trial = Self.freeTrialText(for: product) {
				Text(trial)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
		}

		Button {
			analytics?.track(.subscribeTapped)
			Task {
				isWorking = true
				let outcome = await subscriptionState.purchase(product)
				isWorking = false
				// Dismiss on the outcome, not on the published entitlement: the verified
				// transaction is the proof of purchase, and `isSubscribed` recomputes from an
				// async entitlement sequence that may not have caught up yet.
				if outcome == .subscribed { dismiss() }
				notice = SubscriptionNotice.forPurchase(outcome)
			}
		} label: {
			Text(L10n.Paywall.subscribe)
				.fontWeight(.bold)
				.frame(maxWidth: .infinity)
		}
		.buttonStyle(.borderedProminent)
		.tint(.green)
		.controlSize(.large)
		.disabled(isWorking || subscriptionState.isSubscribed)
		.testability(Testability.Button.paywallSubscribe)
		// In non-production builds the purchase runs against Apple's Sandbox (no real
		// charge); flag the button so testers know it's safe to tap (AIA-0354).
		.underConstructionBadge()
	}

	/// Apple's standard "Manage Subscriptions" deep link. The hardcoded literal always
	/// parses, so the force-unwrap cannot fail.
	// swiftlint:disable:next force_unwrapping
	private static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

	/// Apple's standard EULA, accepted as the Terms of Use when no custom one is provided.
	// swiftlint:disable:next force_unwrapping
	private static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

	/// "Free for 1 month, then €9.99" when the product carries an introductory free-trial
	/// offer; `nil` otherwise. The length and price come from the product (configured in
	/// App Store Connect), so the copy follows whatever offer ships.
	private static func freeTrialText(for product: Product) -> String? {
		guard let offer = product.subscription?.introductoryOffer,
			  offer.paymentMode == .freeTrial else { return nil }
		return L10n.Paywall.trialFormat(offer.period.localizedDescription, product.displayPrice)
	}
}

#if DEBUG
#Preview("Not subscribed") {
	PaywallView(subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true), analytics: nil)
}

#Preview("Subscribed") {
	let state = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed), isPaymentsEnabled: true)
	return PaywallView(subscriptionState: state, analytics: nil)
		.task { await state.start() }
}
#endif
