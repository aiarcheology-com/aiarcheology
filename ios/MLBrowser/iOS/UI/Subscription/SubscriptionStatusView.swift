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
/// changes plan). This keeps us clear of App Review issues around in-app cancellation.
///
/// There is deliberately **no in-app refund entry point** (AIA-0455). Apple mandates none —
/// Guideline 3.1.2's in-app disclosure list is closed and contains no refund affordance — and
/// `refundRequestSheet` could not be made to work on iOS-on-Mac, where its dismissal never
/// crosses the remote→host bridge and the orphaned presentation eats all input. Keeping it on
/// iPhone/iPad alone would have broken cross-platform parity, so it was removed everywhere.
/// Refunds are Apple's to administer, via reportaproblem.apple.com and the receipt email.
struct SubscriptionStatusView: View {
	@ObservedObject var subscriptionState: SubscriptionState

	@State private var isWorking = false
	@State private var showManage = false

	/// Restore feedback (AIA-0376): this Restore button was silent on every outcome.
	@State private var notice: SubscriptionNotice?

	/// True while any StoreKit flow owns this screen — a restore round-trip, or a system
	/// sheet on its way up.
	///
	/// Each action consults this in its own closure instead of the actions disabling one
	/// another through `.disabled`. Same protection against overlapping StoreKit flows, but a
	/// guard costs no re-render — and a row whose attributes depend on a presentation flag is
	/// the churn class that wedged StoreKit sheet dismissal on iOS-on-Mac (AIA-0448).
	private var isBusy: Bool { isWorking || showManage }

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
				Button(L10n.Paywall.manage) {
					guard isBusy.not else { return }
					// Not every host can present StoreKit's sheet. On iOS-on-Mac the system
					// rejects the request and the modifier below has nowhere to report it, so
					// the tap did nothing at all — no sheet, no error (AIA-0448's family).
					// Apple's account page is the substitute, and it is the same destination
					// the paywall's "Manage Subscription" already sends people to.
					guard HostPlatform.current.supportsManageSubscriptionsSheet else {
						openManageSubscriptionsPage()
						return
					}
					showManage = true
				}

				Button {
					guard isBusy.not else { return }
					// Synchronous, before the Task: the body runs on a later turn of the main
					// actor, so a second tap can enqueue a second restore before a flag set
					// inside the Task would stop it.
					isWorking = true
					Task {
						defer { isWorking = false }
						let outcome = await subscriptionState.restore()
						notice = SubscriptionNotice.forRestore(outcome)
					}
				} label: {
					HStack {
						Text(L10n.Paywall.restore)
						Spacer()
						if isWorking { ProgressView() }
					}
				}
				.disabled(isWorking)
			}
		}
		.navigationTitle(L10n.Auth.Account.subscription)
		.navigationBarTitleDisplayMode(.inline)
		// Stays attached unconditionally: on hosts without the sheet the button never flips
		// `showManage`, so this is inert there. Making the modifier itself conditional would
		// mean a structurally different view per platform for no gain.
		.manageSubscriptionsSheet(isPresented: $showManage)
		.alert(notice?.title ?? L10n.Alert.Error.title, isPresented: .init(
			get: { notice != nil },
			set: { if !$0 { notice = nil } }
		)) {
			Button(L10n.Common.ok, role: .cancel) {}
		} message: {
			Text(notice?.message ?? "")
		}
		.task { await subscriptionState.loadProducts() }
	}

	/// Opens Apple's subscription management page, for hosts where StoreKit's in-app sheet
	/// cannot be presented (``HostPlatform/supportsManageSubscriptionsSheet``).
	///
	/// The result is checked rather than discarded. A "Manage Subscription" action that
	/// silently does nothing is precisely the failure this path exists to repair, so a refusal
	/// has to leave a trace instead of reproducing the bug one layer down.
	private func openManageSubscriptionsPage() {
		Task { @MainActor in
			let opened = await UIApplication.shared.open(.appleManageSubscriptions)
			if opened.not {
				LoggingPolicy.warning(
					"The system declined to open Apple's manage-subscriptions page.",
					logger: .state
				)
				notice = .init(title: L10n.Alert.Error.title, message: L10n.Alert.Error.unexpected)
			}
		}
	}

	/// The plan's price with its billing term, e.g. "$3.99 / month".
	///
	/// Shares its composition with the paywall (AIA-0559) rather than repeating it. Note what that
	/// means before editing: the paywall's copy of this line is an App Review 3.1.2 surface, so a
	/// change here **does** rewrite the sign-up screen. That is the point — the alternative was two
	/// implementations, where the same edit rewrites one of them and nobody notices the other.
	private var planText: String? {
		subscriptionState.products.first?.localizedPriceWithTerm
	}

	/// The current period's end date, formatted, if known.
	private var renewalText: String? {
		guard let date = subscriptionState.currentExpirationDate else { return nil }
		return date.formatted(date: .abbreviated, time: .omitted)
	}
}
