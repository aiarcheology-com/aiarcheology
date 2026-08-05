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

	/// Read the flag snapshot directly from the state object (never through `appState`), and note
	/// this view is pushed inside the Settings sheet — that sheet must re-inject `featureFlags`
	/// (DrawerContent) or this `@EnvironmentObject` traps at runtime. See FEATUREFLAGS.md / AGENTS §3.
	@EnvironmentObject private var featureFlags: FeatureFlagsState

	@State private var isWorking = false
	@State private var showManage = false
	@State private var showRefund = false

	/// Restore feedback (AIA-0376): this Restore button was silent on every outcome.
	@State private var notice: SubscriptionNotice?

	/// Identifies the current refund-sheet presentation so the polling watchdog can tell
	/// "this presentation is still up" from "a new sheet was opened meanwhile" (AIA-0448).
	@State private var refundGeneration = 0

	/// True while any StoreKit flow owns this screen — a restore round-trip, or a system
	/// sheet on its way up.
	///
	/// Each action consults this in its own closure instead of the actions disabling one
	/// another through `.disabled`. Same protection against overlapping StoreKit flows, but a
	/// guard costs no re-render: making a row's attributes depend on `showRefund` is the churn
	/// class that wedged the refund sheet's dismissal on iOS-on-Mac (AIA-0448).
	private var isBusy: Bool { isWorking || showRefund || showManage }

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

				// AIA-0461: the "Request a Refund" entry point is gated behind a remote flag so it
				// can be withdrawn without a release. The flag is LIVE — ConfigCat's auto-poll can
				// flip it mid-session — so `|| showRefund` keeps the row in the tree while its own
				// refund sheet is presented. Without that, a flip to off would structurally remove
				// the row hosting `.refundRequestSheet` mid-presentation, the exact AIA-0448 churn
				// class that wedged the sheet's dismissal on iOS-on-Mac.
				if let transactionID = subscriptionState.currentTransactionID,
					featureFlags.snapshot.isRefundRequestEnabled || showRefund {
					// While the sheet is up, feedback may only change ATTRIBUTES of this row
					// (opacity), never its STRUCTURE. Inserting/removing views here at
					// presentation time — the spinner swap, a footnote row, `.disabled` — was
					// correlated with the sheet's dismissal never reaching the app on
					// iOS-on-Mac (terminal hang), while the structurally static row recovered
					// (AIA-0448). The spinner is therefore always in the tree and only fades in.
					Button(role: .destructive) {
						guard isBusy.not else { return }
						LoggingPolicy.info(
							"Refund requested for transaction \(transactionID) — asking StoreKit to present Apple's refund sheet…",
							logger: .state
						)
						refundGeneration += 1
						showRefund = true
						startRefundWatchdogOnMac()
					} label: {
						HStack {
							Text(L10n.Paywall.requestRefund)
							Spacer()
							// Decorative, and hidden from VoiceOver with a CONSTANT — a
							// dynamic `.accessibilityHidden(showRefund.not)` would be one more
							// attribute mutating on the presenting row at exactly the wrong
							// moment (AIA-0448).
							ProgressView()
								.opacity(showRefund ? 1 : 0)
								.accessibilityHidden(true)
						}
					}
					.testability(Testability.Button.settingsRequestRefund)
					.refundRequestSheet(for: transactionID, isPresented: $showRefund) { result in
						LoggingPolicy.info("Refund sheet dismissed: \(result)", logger: .state)
						notice = SubscriptionNotice.forRefund(result)
						// Re-read entitlements now: on iOS-on-Mac the revocation's live
						// Transaction.updates push never survives the bridge and the scene
						// never backgrounds, so nothing else re-reads until relaunch
						// (AIA-0448). Harmless in production — dismissal only means Apple
						// RECEIVED the request, so the scan finds nothing revoked and the
						// gate correctly stays down until real approval arrives.
						Task { await subscriptionState.start() }
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
	}

	/// AIA-0448, Mac only. On iOS-on-Mac every PUSH signal about the refund sheet dies in
	/// the broken remote→host bridge: `onDismiss` never fires, and no scene notification
	/// (foreground, focus) arrives while the phantom presentation eats input. So this PULLs:
	/// a task we fully own polls the store while the sheet is marked presented. In the
	/// testing environments a submitted refund auto-approves within seconds, so its
	/// revocation appears in the local store; the entitlement re-read then publishes
	/// `isSubscribed == false`, the root gate swaps to the paywall — tearing down this whole
	/// Settings hierarchy, phantom included — and the sheet flag is released.
	///
	/// Bounded at ~5 minutes: in production a refund decision takes days, and a request the
	/// user abandoned must not leave a polling loop running for the app's lifetime. On iOS
	/// the watchdog never starts; `onDismiss` does this job there.
	private func startRefundWatchdogOnMac() {
		// `.macDesignedForiPad`, not `.isMac`: the bug is specific to the iOS-on-Mac
		// runtime. Catalyst hosts StoreKit UI differently and is untested here, so it
		// must not silently inherit a workaround for a bug it may not have.
		guard HostPlatform.current == .macDesignedForiPad else { return }
		let generation = refundGeneration
		Task { @MainActor in
			for _ in 0..<150 {
				try? await Task.sleep(for: .seconds(2))
				guard showRefund, refundGeneration == generation else { return }
				await subscriptionState.start()
				if !subscriptionState.isSubscribed {
					LoggingPolicy.warning(
						"Refund revocation detected by polling — releasing the sheet flag"
							+ " (iOS-on-Mac bridge loss).",
						logger: .state
					)
					showRefund = false
					return
				}
			}
			LoggingPolicy.info("Refund watchdog expired without a revocation.", logger: .state)
		}
	}

	/// The plan's price with its billing term, e.g. "$3.99 / month".
	///
	/// Shares its composition with the paywall (AIA-0559) rather than repeating it: the paywall's
	/// copy of this line is an App Review 3.1.2 surface, and a Settings-side edit that quietly
	/// rewrote the sign-up screen is exactly the failure one implementation prevents.
	private var planText: String? {
		subscriptionState.products.first?.localizedPriceWithTerm
	}

	/// The current period's end date, formatted, if known.
	private var renewalText: String? {
		guard let date = subscriptionState.currentExpirationDate else { return nil }
		return date.formatted(date: .abbreviated, time: .omitted)
	}
}
