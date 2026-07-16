//
//  SubscriptionStatusView.swift
//  AI Archeology
//
//  Subscription management submenu (AIA-0343).
//

import SwiftUI
import StoreKit
import UIKit

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

	/// Restore feedback (AIA-0376): this Restore button was silent on every outcome.
	@State private var notice: SubscriptionNotice?

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

				Button {
					Task {
						isWorking = true
						let outcome = await subscriptionState.restore()
						isWorking = false
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

				if let transactionID = subscriptionState.currentTransactionID {
					// While the sheet is up, feedback may only change ATTRIBUTES of this row
					// (opacity), never its STRUCTURE. Inserting/removing views here at
					// presentation time — the spinner swap, a footnote row, `.disabled` — was
					// correlated with the sheet's dismissal never reaching the app on
					// iOS-on-Mac (terminal hang), while the structurally static row recovered
					// (AIA-0448). The spinner is therefore always in the tree and only fades in.
					Button(role: .destructive) {
						LoggingPolicy.info(
							"Refund requested for transaction \(transactionID) — asking StoreKit to present Apple's refund sheet…",
							logger: .state
						)
						showRefund = true
					} label: {
						HStack {
							Text(L10n.Paywall.requestRefund)
							Spacer()
							ProgressView().opacity(showRefund ? 1 : 0)
						}
					}
					.refundRequestSheet(for: transactionID, isPresented: $showRefund) { result in
						LoggingPolicy.info("Refund sheet dismissed: \(result)", logger: .state)
						notice = SubscriptionNotice.forRefund(result)
					}
				}
			}
		}
		.navigationTitle(L10n.Auth.Account.subscription)
		.navigationBarTitleDisplayMode(.inline)
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
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
			releaseOrphanedRefundPresentationOnMac()
		}
	}

	/// AIA-0448, Mac only. On iOS-on-Mac, StoreKit's refund UI closes without ever delivering
	/// its dismissal to this process: `onDismiss` never fires, `showRefund` stays true, and the
	/// orphaned host-side presentation blocks every touch until force-quit. The scene returning
	/// to the foreground is the one signal that *does* arrive when the remote UI goes away
	/// (it took the scene with it while presented), so the presentation is released from our
	/// side — host-initiated dismissal doesn't need the broken remote→host channel.
	///
	/// The grace period lets a well-behaved dismissal (should Apple fix the bridge) deliver its
	/// result and flip `showRefund` first; the release then finds nothing to do. On iOS the
	/// refund sheet never backgrounds the scene, and the Mac guard keeps this from firing there
	/// at all. Known cost: clicking the app's window on the Mac while Apple's form is still open
	/// also foregrounds the scene and would close the form — recoverable by re-requesting,
	/// unlike the force-quit it replaces.
	private func releaseOrphanedRefundPresentationOnMac() {
		guard HostPlatform.current.isMac, showRefund else { return }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(1.5))
			guard showRefund else { return }
			LoggingPolicy.warning(
				"Refund sheet never delivered its dismissal — releasing the orphaned presentation"
					+ " (iOS-on-Mac teardown bug).",
				logger: .state
			)
			showRefund = false
		}
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
