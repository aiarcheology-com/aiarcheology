//
//  SubscriptionStatusView.swift
//  AI Archeology
//
//  Subscription management submenu (AIA-0343).
//

import SwiftUI
import StoreKit

/// Pushed from Settings → Account → Subscription. Shows the subscription status (plan /
/// state / renewal date) and routes all management through **Apple's native sheets** —
/// the App Store-compliant approach. iOS does not allow an app to cancel a subscription
/// itself, so "Manage Subscription" opens Apple's manage sheet (where the user cancels or
/// changes plan); refunds go through Apple's refund sheet. This keeps us clear of App
/// Review issues around in-app cancellation.
struct SubscriptionStatusView: View {
	@ObservedObject var subscriptionState: SubscriptionState

	@State private var isWorking = false
	@State private var showManage = false
	@State private var showRefund = false

	var body: some View {
		Form {
			Section {
				if let plan = planText {
					LabeledContent(L10n.Subscription.plan, value: plan)
				}
				LabeledContent(
					L10n.Subscription.state,
					value: subscriptionState.isInTrial ? L10n.Subscription.trial : L10n.Paywall.active
				)
				if let renews = renewalText {
					// During the free trial the date is when the trial ends (and the first
					// charge happens); afterwards it's the renewal date.
					LabeledContent(
						subscriptionState.isInTrial ? L10n.Subscription.trialEnds : L10n.Subscription.renews,
						value: renews
					)
				}
			}

			Section {
				// Cancel / change plan happens in Apple's native sheet (Apple doesn't permit
				// in-app programmatic cancellation — this is the compliant path).
				Button(L10n.Paywall.manage) { showManage = true }

				Button(L10n.Paywall.restore) {
					Task {
						isWorking = true
						await subscriptionState.restore()
						isWorking = false
					}
				}
				.disabled(isWorking)

				if let transactionID = subscriptionState.currentTransactionID {
					Button(L10n.Paywall.requestRefund, role: .destructive) {
						showRefund = true
					}
					.refundRequestSheet(for: transactionID, isPresented: $showRefund)
				}
			}
		}
		.navigationTitle(L10n.Auth.Account.subscription)
		.navigationBarTitleDisplayMode(.inline)
		.manageSubscriptionsSheet(isPresented: $showManage)
		.task { await subscriptionState.loadProducts() }
	}

	/// The plan's price with its billing term, e.g. "$3.99 / month". Falls back to the bare
	/// price when the subscription period can't be resolved (no regression vs. before).
	private var planText: String? {
		guard let product = subscriptionState.products.first else { return nil }
		guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
		return L10n.Subscription.planTerm(product.displayPrice, period.localizedTerm)
	}

	/// The current period's end date, formatted, if known.
	private var renewalText: String? {
		guard let date = subscriptionState.currentExpirationDate else { return nil }
		return date.formatted(date: .abbreviated, time: .omitted)
	}
}
