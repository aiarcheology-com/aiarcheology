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

/// The paywall. Presented from the Settings "Upgrade" entry point. Reads products and
/// entitlement from ``SubscriptionState`` and drives purchase / restore intents.
struct PaywallView: View {
	@ObservedObject var subscriptionState: SubscriptionState
	@Environment(\.dismiss) private var dismiss

	/// Disables the action buttons while a purchase/restore round-trip is in flight.
	@State private var isWorking = false

	/// Drives Apple's in-app refund request sheet for the active subscription.
	@State private var showRefund = false

	var body: some View {
		VStack(spacing: 24) {
			Spacer()

			Image(systemName: "crown.fill")
				.font(.system(size: 56))
				.foregroundStyle(.yellow)
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
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.task {
			// Load products when the paywall appears (kept off the launch path so a slow
			// App Store fetch never delays app readiness).
			await subscriptionState.loadProducts()
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
				await subscriptionState.restore()
				isWorking = false
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
	}

	@ViewBuilder
	private func productSection(_ product: Product) -> some View {
		VStack(spacing: 4) {
			Text(product.displayName)
				.font(.headline)
			Text(product.displayPrice)
				.font(.title2).bold()

			// Free-trial terms, if the product offers an introductory free trial. The
			// length/price come from the product itself (set in App Store Connect), so
			// the copy follows whatever offer is configured.
			if let trial = Self.freeTrialText(for: product) {
				Text(trial)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
		}

		Button {
			Task {
				isWorking = true
				await subscriptionState.purchase(product)
				isWorking = false
				if subscriptionState.isSubscribed { dismiss() }
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
	}

	/// Apple's standard "Manage Subscriptions" deep link. The hardcoded literal always
	/// parses, so the force-unwrap cannot fail.
	// swiftlint:disable:next force_unwrapping
	private static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

	/// "Free for 7 days, then €9.99" when the product carries an introductory free-trial
	/// offer; `nil` otherwise. The length and price come from the product (configured in
	/// App Store Connect), so the copy follows whatever offer ships.
	private static func freeTrialText(for product: Product) -> String? {
		guard let offer = product.subscription?.introductoryOffer,
			  offer.paymentMode == .freeTrial else { return nil }
		let period = offer.period
		let unit: String
		switch period.unit {
		case .day: unit = "day"
		case .week: unit = "week"
		case .month: unit = "month"
		case .year: unit = "year"
		@unknown default: unit = "period"
		}
		let count = period.value
		let periodText = "\(count) \(unit)\(count == 1 ? "" : "s")"
		return L10n.Paywall.trialFormat(periodText, product.displayPrice)
	}
}

#if DEBUG
#Preview("Not subscribed") {
	PaywallView(subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed)))
}

#Preview("Subscribed") {
	let state = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed))
	return PaywallView(subscriptionState: state)
		.task { await state.start() }
}
#endif
