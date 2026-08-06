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

/// A message the paywall owes the user (AIA-0376).
///
/// Carries its own title because not every outcome is an error: Ask-to-Buy and
/// "nothing to restore" are ordinary answers and must not be dressed as failures.
///
/// Deliberately a plain value: no `id`, so `Equatable` compares what is actually shown.
/// A `UUID` id would make two identical notices unequal, quietly defeating both the
/// conformance and SwiftUI's diffing.
struct SubscriptionNotice: Equatable {
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

	/// What to say once Apple's refund sheet closes (AIA-0448).
	///
	/// Reports only that the request *reached Apple* — never that money is coming back. Apple
	/// decides refunds on its own schedule, and the decision arrives later as a revocation
	/// that drops the entitlement and raises the gate. Copy promising an outcome here would be
	/// a promise we cannot keep.
	///
	/// `.userCancelled` stays silent for the same reason `.cancelled` does: the user closed
	/// Apple's form themselves and needs no report of their own decision.
	///
	/// `StoreKit.Transaction` is spelled out because SwiftUI publishes its own `Transaction`
	/// and both are in scope in this file.
	static func forRefund(
		_ result: Result<StoreKit.Transaction.RefundRequestStatus, StoreKit.Transaction.RefundRequestError>
	) -> SubscriptionNotice? {
		switch result {
		case .success(let status):
			switch status {
			case .success:
				return .init(title: L10n.Subscription.Refund.Submitted.title,
							 message: L10n.Subscription.Refund.Submitted.message)
			case .userCancelled:
				return nil
			@unknown default:
				return nil
			}
		case .failure(let error):
			switch error {
			case .duplicateRequest:
				return .init(title: L10n.Subscription.Refund.Duplicate.title,
							 message: L10n.Subscription.Refund.Duplicate.message)
			case .failed:
				return .init(title: L10n.Alert.Error.title, message: L10n.Subscription.Refund.Failed.message)
			@unknown default:
				return .init(title: L10n.Alert.Error.title, message: L10n.Subscription.Refund.Failed.message)
			}
		}
	}
}

/// What the app-managed free-access window (AIA-0556) has to say on a given presentation.
///
/// Two cases rather than a day count plus a flag, because they read differently and must not be
/// confusable: day 0 states an offer the user has not taken yet, while the reminder states what is
/// left of one they are already inside. Both carry the date the window runs out — the date a
/// subscription has to start by.
enum FreeAccessOffer: Equatable {
	/// The window is being offered. `days` is its whole length.
	case offered(days: Int, endsOn: Date)

	/// The window is running and this is the reminder. `days` is what remains of it.
	case remaining(days: Int, endsOn: Date)

	var endsOn: Date {
		switch self {
		case let .offered(_, endsOn), let .remaining(_, endsOn): endsOn
		}
	}

	/// The headline, pluralized: "14 days free" on day 0, "7 days left" at the reminder.
	var headline: String {
		switch self {
		case let .offered(days, _): L10n.Paywall.FreeAccess.daysFree(days)
		case let .remaining(days, _): L10n.Paywall.FreeAccess.daysLeft(days)
		}
	}
}

/// The paywall. Presented as the whole-app root gate (`SubscriptionGateView`) when the
/// signed-in user isn't subscribed. Reads products and entitlement from
/// ``SubscriptionState`` and drives purchase / restore intents.
///
/// The free-access controls (AIA-0556) are **optional and independently absent**: no
/// `continueAction` means no Continue button, no `freeAccessOffer` means no window copy. The hard
/// wall and the Settings sheet pass neither and keep the screen they had — acceptance criterion 8.
///
/// ``showsBillingEstimate`` is the third, and it is deliberately independent of both: criterion 9
/// asks for the date billing begins **at the wall**, which is the one screen carrying no offer at
/// all. It stays off wherever the feature does not reach, so a flag-off build and the Settings sheet
/// keep develop's paywall exactly. See ``billingNote(for:)`` for why that date is hedged before a
/// purchase and exact after one.
struct PaywallView: View {
	@ObservedObject var subscriptionState: SubscriptionState
	let analytics: AnalyticsState?

	/// Auth state, supplied only when the paywall is the whole-app root gate, so a
	/// non-subscriber can sign out or delete their account (Apple 5.1.1(v)). `nil` when
	/// presented from Settings (sign-out/delete live in the Clerk profile there).
	var authState: AuthState?

	/// The findings store, supplied only by the root gate (AIA-0556). `nil` everywhere the user has
	/// a way back into the app, because that is where the findings inventory already lives.
	var findingRepository: FindingRepository?

	/// True when this is the whole-app root gate (vs. the Settings sheet). Enables the
	/// account affordances.
	var isRootGate = false

	/// Which account controls to show, passed as a **value** from the parent (AIA-0536).
	///
	/// Deliberately not read from `authState`: that is a plain `var`, not an `@ObservedObject`, so
	/// this view does not re-render when the context changes. It never had to before — signing out
	/// tore down the whole view tree, because auth was the outer gate. The paywall now stays mounted
	/// across a sign-out and has to swap Sign Out / Delete for Sign In in place, so the value comes
	/// from `SubscriptionGateView`, which *does* observe auth.
	var authContext: EffectiveAuthContext = .indeterminate

	/// What to do when the user declines to subscribe *for now* — `nil` wherever that is not an
	/// option (AIA-0556).
	///
	/// Presence is the whole switch between an informational paywall and a wall. At the wall there
	/// is nothing to continue past, and in the Settings sheet dismissal is the sheet's own, so both
	/// pass `nil` and get today's screen unchanged.
	var continueAction: (() -> Void)?

	/// The free-access window this presentation is about, or `nil` when there is none to state.
	///
	/// Independent of ``continueAction`` on purpose: the copy is about the window, the button is
	/// about the exit, and a caller that has one without the other is not a contradiction.
	var freeAccessOffer: FreeAccessOffer?

	/// Whether to state when billing begins (acceptance criterion 9).
	///
	/// Separate from ``freeAccessOffer`` because the two are needed at different moments. The day-0
	/// screen and the reminder carry an offer *and* want the date; the hard wall carries no offer —
	/// the window is already spent — yet is precisely where criterion 9 asks for it, because the
	/// question there is "if I subscribe now, when am I charged".
	///
	/// Default `false` so the screens that are not part of this feature keep the paywall they had:
	/// with the flag off, and from Settings, nothing about a free period renders. That is acceptance
	/// criterion 8, and it is what makes the feature revertible by a dashboard switch alone.
	var showsBillingEstimate = false

	@Environment(\.dismiss) private var dismiss

	/// Real vs. mock auth from the composition root (AIA-0385); forwarded into the sign-in sheet.
	@Environment(\.usesRealAuth) private var usesRealAuth

	/// The purchase/restore round-trip currently in flight, or `nil` when idle. Knowing
	/// *which* action runs (not just a Bool) lets the tapped button show its own spinner —
	/// without it the disabled buttons read as a frozen app while StoreKit takes seconds
	/// to present its sheet (AIA-0448).
	private enum InFlightAction {
		case purchase
		case restore
	}
	@State private var inFlight: InFlightAction?

	/// Presents the contextual sign-in sheet from the root paywall (AIA-0536).
	@State private var showSignIn = false

	/// Drives Apple's in-app refund request sheet for the active subscription.
	@State private var showRefund = false

	/// Identifies the current refund-sheet presentation so the polling watchdog can tell
	/// "this presentation is still up" from "a new sheet was opened meanwhile" (AIA-0448)
	/// — see SubscriptionStatusView.
	@State private var refundGeneration = 0

	/// True while any StoreKit flow owns this screen — a purchase/restore round-trip, or the
	/// refund sheet on its way up. Consulted inside each action rather than via `.disabled`
	/// on its siblings; see ``SubscriptionStatusView/isBusy`` for why (AIA-0448).
	private var isBusy: Bool { inFlight != nil || showRefund }

	/// Presents the in-app Privacy Policy (App Review requires it on the purchase screen).
	@State private var showPrivacy = false

	/// Root-gate account actions (Apple 5.1.1(v)): confirm before deleting.
	@State private var showDeleteConfirmation = false

	/// What the screen owes the user — a purchase/restore outcome, or a failed account
	/// deletion; `nil` while there is nothing to say (AIA-0376).
	@State private var notice: SubscriptionNotice?

	/// Whether *this user* is still eligible for the introductory free trial, or `nil` until
	/// StoreKit has said. A user who already used the trial is charged the full price immediately,
	/// so the "free for N" copy must only show when they'd actually get it (else it's misleading /
	/// an App Review risk). Resolved per-user from StoreKit on appear.
	///
	/// Three-valued rather than a `Bool` defaulting to `false`, because both answers now render
	/// copy: eligible states when the trial ends, ineligible states that billing starts at once
	/// (AIA-0556). A `false` default would put the ineligible sentence on screen for the fraction of
	/// a second before StoreKit answers, and then swap it for the opposite claim — a flicker between
	/// two contradictory statements about money. Unresolved says nothing, which is what the previous
	/// default achieved by accident and this makes explicit.
	@State private var introOfferEligibility: Bool?

	/// Whether this install has anything saved that a user walking away would still want (AIA-0556).
	///
	/// Read once on appear rather than on every render: a Core Data count is cheap, but this screen
	/// re-renders on every StoreKit tick and the answer only ever changes from the button below it.
	/// `false` until answered, so an install with nothing saved keeps develop's paywall exactly.
	@State private var hasSavedFindings = false

	/// Drives the Export / Delete / Cancel confirmation for the saved findings.
	@State private var showRemoveFindings = false

	/// True while the export ZIP is being built, before the share sheet appears. Only fades the
	/// button's spinner and disables it — it never restructures the button, because structural churn
	/// on a view the share sheet is presented from wedges the dismissal on iOS-on-Mac (AIA-0448).
	@State private var isExportingFindings = false

	@State private var findingsSharePayload: ActivitySharePayload?

	/// Whether this paywall is the only screen the user has.
	///
	/// Not the same question as ``isRootGate``, which is also true of the informational day-0 and
	/// reminder presentations (AIA-0556) — those have the whole app, and with it the findings
	/// inventory, one Continue away. Only the hard wall is a dead end, and only a dead end owes the
	/// user a way to get their data out of it.
	private var isDeadEnd: Bool { isRootGate && continueAction == nil }

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
						Text(L10n.Paywall.title)
							.font(.title).bold()
							.multilineTextAlignment(.center)
						Text(L10n.Paywall.tagline)
							.font(.body)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
					}
					.padding(.horizontal, 32)

					// The free-access window, stated as the offer plus the date a subscription has to start
					// by (acceptance criterion 9). Absent on the wall, where there is no window left to state.
					if let freeAccessOffer {
						VStack(spacing: 6) {
							Text(freeAccessOffer.headline)
								.font(.headline)
								.testability(Testability.Label.paywallFreeAccessHeadline)
							Text(L10n.Paywall.FreeAccess.subscribeBy(
								freeAccessOffer.endsOn.formatted(date: .abbreviated, time: .omitted)
							))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
							// The date is the point of the sentence — let it wrap rather than truncate under
							// vertical compression or large Dynamic Type.
							.fixedSize(horizontal: false, vertical: true)
						}
						.padding(.horizontal, 32)
					}

					if subscriptionState.isSubscribed {
						Label(L10n.Paywall.active, systemImage: "checkmark.seal.fill")
							.foregroundStyle(.green)
							.font(.headline)
					}

					Spacer(minLength: 0)

					content
						.padding(.horizontal, 32)
						.padding(.bottom, 24)
				}
				// When the content is short, this minimum height lets the two spacers retain the
				// centered layout. When landscape, Dynamic Type, or extra disclosures make it taller,
				// the stack grows past the viewport and the ScrollView exposes every control instead of
				// clipping the top or bottom of the purchase screen.
				.frame(maxWidth: 480)
				.frame(maxWidth: .infinity, minHeight: geometry.size.height)
			}
			.testability(Testability.View.paywallContent)
		}
		.task {
			// Load products when the paywall appears (kept off the launch path so a slow
			// App Store fetch never delays app readiness), then resolve this user's
			// intro-offer eligibility so the trial copy only shows when they'd get it.
			await subscriptionState.loadProducts()
			if let subscription = subscriptionState.products.first?.subscription {
				introOfferEligibility = await subscription.isEligibleForIntroOffer
			}
		}
		.onAppear {
			analytics?.track(.paywallShown)
			// Only the dead end offers this, so only the dead end pays for the count (AIA-0556).
			if isDeadEnd { hasSavedFindings = findingRepository?.hasAnyFinding() == true }
		}
		// The export share sheet is attached at the same level as the paywall's own content rather
		// than to the button, so its presenter outlives the confirmation dialog's dismissal — the
		// ZIP is built after a delay and the presenter must still be in the tree when it lands
		// (AIA-0303/0402/0448, mirroring Settings → Reset).
		.activityShareSheet($findingsSharePayload)
		// Export and Delete are independent explicit choices, exactly as in Settings → Reset:
		// exporting never deletes, and the user re-opens this to delete. A `.confirmationDialog`
		// rather than a second `.alert`, because this screen deliberately keeps one alert for
		// everything it has to say — the delete-account confirmation below is the precedent for
		// stacking a second dialog alongside that one.
		.confirmationDialog(
			L10n.Settings.Reset.RemoveFindings.title,
			isPresented: $showRemoveFindings,
			titleVisibility: .visible
		) {
			Button(L10n.Settings.Reset.RemoveFindings.export) {
				exportFindings()
			}
			.testability(Testability.Button.paywallFindingsExport)

			Button(L10n.Settings.Reset.RemoveFindings.delete, role: .destructive) {
				removeAllFindings()
			}
			.testability(Testability.Button.paywallFindingsDelete)

			Button(L10n.Common.cancel, role: .cancel) {}
		} message: {
			Text(L10n.Settings.Reset.RemoveFindings.message)
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
						notice = .init(title: L10n.Alert.Error.title, message: L10n.Alert.Error.unexpected)
					}
				}
			}
			.testability(Testability.Button.paywallDeleteAccountConfirm)

			Button(L10n.Common.cancel, role: .cancel) {}
		} message: {
			Text(L10n.Auth.Account.Delete.message)
		}
		// One alert for everything this screen has to say — purchase, restore, and a failed
		// account deletion (AIA-0376). Chaining a second `.alert` onto the same view risks
		// SwiftUI honouring only one of them, and there is nothing to gain from the split:
		// each is a title plus a message with an OK button.
		//
		// Before this, every non-success purchase outcome ended with the spinner stopping and
		// nothing else — the user stared at an unchanged paywall.
		.alert(notice?.title ?? L10n.Alert.Error.title, isPresented: .init(
			get: { notice != nil },
			set: { if !$0 { notice = nil } }
		)) {
			Button(L10n.Common.ok, role: .cancel) {}
		} message: {
			Text(notice?.message ?? "")
		}
		// Contextual sign-in from the root paywall (AIA-0536). The account controls above are the
		// only route a signed-out lapsed subscriber has to their own account, so this must be
		// reachable without a purchase.
		.sheet(isPresented: $showSignIn) {
			if let authState {
				SignInSheet(authState: authState)
					// Re-inject across the sheet boundary (AGENTS.md §3): `SignInSheet` uses this to
					// decide whether to build Clerk's `AuthView`, and the mock path has no configured
					// Clerk instance, so losing it here traps rather than degrades.
					.environment(\.usesRealAuth, usesRealAuth)
			}
		}
	}

	/// AIA-0448, Mac only — the same pull-based watchdog as ``SubscriptionStatusView``,
	/// where the full story is documented: on iOS-on-Mac every push signal about the refund
	/// sheet dies in the broken remote→host bridge, so a polling task we own detects the
	/// auto-approved revocation in the store and releases the sheet flag.
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

	@ViewBuilder
	private var content: some View {
		if let product = subscriptionState.products.first {
			productSection(product)

			// The free-access window presents two legitimate paths: subscribe now or keep using
			// the app until it ends. Keep that choice explicit between the equally sized actions.
			if continueAction != nil {
				Text(L10n.Paywall.or)
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.secondary)
			}
		} else {
			// Empty product list: App Store Connect not configured yet, the local
			// .storekit file isn't wired into the scheme, or the mock path. Degrade
			// gracefully rather than showing a dead Subscribe button.
			Text(L10n.Paywall.unavailable)
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}

		// Directly under Subscribe and shaped like it — same prominence, same control size, same
		// full width — so it reads as a real second choice rather than a way out of the screen.
		// The tint is what keeps the hierarchy: a desaturated slate blue against Subscribe's green,
		// from a colorset with its own dark appearance because the app hardcodes no colours
		// (`Assets.xcassets/ContinueButton`, both appearances ≥ 4.5:1 against a white label).
		//
		// Rendered only when a caller supplied an action: on the hard wall there is nothing to
		// continue past, and this whole block is absent.
		if let continueAction {
			Button {
				guard isBusy.not else { return }
				continueAction()
			} label: {
				Text(L10n.Paywall.continueButton)
					.fontWeight(.bold)
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.tint(Color(Self.continueButtonColorName, bundle: .main))
			.controlSize(.large)
			.disabled(inFlight != nil)
			.testability(Testability.Button.paywallContinue)
		}

		Button {
			guard isBusy.not else { return }
			// Synchronous, before the Task: the body runs on a later turn of the main actor,
			// so a second tap can enqueue a second restore before a flag set inside the Task
			// would stop it.
			inFlight = .restore
			Task {
				defer { inFlight = nil }
				let outcome = await subscriptionState.restore()
				notice = SubscriptionNotice.forRestore(outcome)
			}
		} label: {
			// Opacity + overlay (not an if/else swap) so the spinner never changes the
			// button's size mid-flight.
			Text(L10n.Paywall.restore)
				.frame(maxWidth: .infinity)
				.opacity(inFlight == .restore ? 0 : 1)
				.overlay { if inFlight == .restore { ProgressView() } }
		}
		.buttonStyle(.bordered)
		.controlSize(.large)
		.disabled(inFlight != nil)
		.testability(Testability.Button.paywallRestore)

		// Request a refund via Apple's native sheet — only for an active subscription
		// (Apple owns the decision; this just opens the request flow).
		if subscriptionState.isSubscribed, let transactionID = subscriptionState.currentTransactionID {
			// While the sheet is up, feedback may only change ATTRIBUTES of this button
			// (opacity), never its STRUCTURE — structural churn at presentation time was
			// correlated with the sheet's dismissal never reaching the app on iOS-on-Mac;
			// see SubscriptionStatusView (AIA-0448). Both the text and the spinner are
			// always in the tree and only trade opacities.
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
				Text(L10n.Paywall.requestRefund)
					.frame(maxWidth: .infinity)
					.opacity(showRefund ? 0 : 1)
					// Decorative, hidden from VoiceOver with a CONSTANT — a dynamic
					// `.accessibilityHidden` would be another attribute mutating on the
					// presenting view at exactly the wrong moment (AIA-0448).
					.overlay {
						ProgressView()
							.opacity(showRefund ? 1 : 0)
							.accessibilityHidden(true)
					}
			}
			.buttonStyle(.bordered)
			.controlSize(.large)
			.testability(Testability.Button.paywallRequestRefund)
			.refundRequestSheet(for: transactionID, isPresented: $showRefund) { result in
				LoggingPolicy.info("Refund sheet dismissed: \(result)", logger: .state)
				notice = SubscriptionNotice.forRefund(result)
				// Dismissal-time entitlement re-read — see SubscriptionStatusView (AIA-0448).
				Task { await subscriptionState.start() }
			}
		}

		// Manage existing subscription (cancel / change plan). Always available so a
		// subscriber can reach Apple's management screen from here.
		Link(L10n.Paywall.manage, destination: Self.manageSubscriptionsURL)
			.font(.footnote)
			.testability(Testability.Link.paywallManage)

		legalFooter

		// The wall is otherwise a dead end for the user's own data: Settings — and with it the
		// findings inventory and its export — sits behind the gate, so an unsubscribed user has no
		// route to the findings they saved during the free period (AIA-0556). Not free-period copy
		// and therefore not flag-gated; it is simply absent when there is nothing saved to reach.
		//
		// No new data layer: this is the same `FindingRepository` + `FindingExporter` pair that
		// Settings → Reset → Remove Findings drives, down to the copy.
		if isDeadEnd, hasSavedFindings {
			Button {
				guard isBusy.not, isExportingFindings.not else { return }
				showRemoveFindings = true
			} label: {
				// Both the label and the spinner are always in the tree and only trade opacities —
				// the same no-structural-churn rule the refund button follows (AIA-0448), because
				// the share sheet is presented from this screen.
				// Its own label rather than Settings' "Remove Findings": here the export is the
				// point — the delete is what Apple and the GDPR ask for alongside it — and a button
				// that only advertises deletion is one nobody looking for their data would press.
				Text(L10n.Paywall.findings)
					.frame(maxWidth: .infinity)
					.opacity(isExportingFindings ? 0 : 1)
					.overlay {
						ProgressView()
							.opacity(isExportingFindings ? 1 : 0)
							.accessibilityHidden(true)
					}
			}
			.buttonStyle(.bordered)
			.controlSize(.large)
			.padding(.top, 8)
			.testability(Testability.Button.paywallRemoveFindings)
		}

		// Whole-app root gate only: account controls, because Settings is unreachable from behind
		// the gate. Apple 5.1.1(v).
		//
		// Which controls depends on whether anyone is signed in (AIA-0536). A signed-out lapsed
		// subscriber is the case that forces this: with only Sign Out / Delete shown, they would
		// have to buy a subscription before they could reach their own account to recover or delete
		// it. Sign In is the fourth entry point and exists for exactly them.
		//
		// `.indeterminate` and `.suspended` deliberately show nothing: the first is transient, and
		// the second cannot reach Clerk anyway, so offering sign-in there only invites a failure.
		if isRootGate, let authState {
			switch authContext {
			case .validated:
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
					.testability(Testability.Button.paywallDeleteAccount)
				}
				.padding(.top, 8)
			case .anonymous:
				Button {
					showSignIn = true
				} label: {
					Text(L10n.Auth.SignIn.button).frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
				.padding(.top, 8)
				.testability(Testability.Button.paywallSignIn)
			case .indeterminate, .suspended:
				EmptyView()
			}
		}
	}

	// MARK: - Findings escape hatch (AIA-0556)

	/// Builds a ZIP of every saved finding and hands it to the share sheet — **without** deleting.
	///
	/// ``FindingsEscapeHatch`` owns the build and returns only once the confirmation dialog has
	/// finished dismissing, so the payload can never present into a dismissing presenter (AIA-0402).
	private func exportFindings() {
		guard let findingRepository else { return }
		isExportingFindings = true
		Task {
			defer { isExportingFindings = false }
			do {
				let url = try await FindingsEscapeHatch.makeShareableZip(from: findingRepository)
				findingsSharePayload = ActivitySharePayload(items: [url])
			} catch {
				LoggingPolicy.error("Failed to export findings from the paywall", error: error, logger: .storage)
				notice = .init(title: L10n.Alert.Error.title, message: L10n.Findings.Export.error)
			}
		}
	}

	/// Permanently deletes every saved finding and its screenshot.
	///
	/// The button retires itself on success rather than waiting for a re-render that this screen has
	/// no reason to perform — nothing here observes Core Data.
	private func removeAllFindings() {
		guard let findingRepository else { return }
		Task {
			do {
				try await findingRepository.removeAllFindings()
				hasSavedFindings = false
			} catch {
				LoggingPolicy.error("Failed to remove all findings from the paywall", error: error, logger: .storage)
				notice = .init(
					title: L10n.Alert.Error.title,
					message: L10n.Settings.Reset.RemoveFindings.error
				)
			}
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

			// What the subscription actually provides, in the words App Store Connect already
			// carries ("Full access to ML Browser."). App Review 3.1.2 asks the sign-up screen to
			// describe the content or services, and the tagline above is the app's pitch, not the
			// product's description — so this comes from the product or not at all.
			if product.description.isEmpty.not {
				Text(product.description)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}

			// Price *and* the period it recurs over (AIA-0559). App Review 3.1.2 wants the
			// sign-up screen to state what the money buys and how often — a bare "$3.99" says
			// neither. Like the disclosure below, it must show in full: this screen is a fixed
			// VStack, so let the line claim its height and wrap rather than truncate the word
			// the guideline is about.
			Text(product.localizedPriceWithTerm)
				.font(.title2).bold()
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
				.accessibilityLabel(product.spokenPriceWithTerm)

			// Free-trial terms — only when *this user* is still eligible (a returning user
			// who already used the trial is charged immediately, so showing "free for N"
			// would be misleading). Length/price come from the product (set in ASC).
			if introOfferEligibility == true, let trial = Self.freeTrialText(for: product) {
				Text(trial)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					// This sentence embeds the price too, so it needs the spoken form for the
					// same reason the price above does — otherwise an eligible user hears
					// "then $3.99 slash month" and only an ineligible one is spared it.
					.accessibilityLabel(Self.spokenFreeTrialText(for: product) ?? trial)
			}

			if showsBillingEstimate {
				billingNote(for: product)
			}
		}

		Button {
			guard isBusy.not else { return }
			analytics?.track(.subscribeTapped)
			// Synchronous, before the Task — see the Restore button above.
			inFlight = .purchase
			Task {
				defer { inFlight = nil }
				let outcome = await subscriptionState.purchase(product)
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
				.opacity(inFlight == .purchase ? 0 : 1)
				.overlay { if inFlight == .purchase { ProgressView() } }
		}
		.buttonStyle(.borderedProminent)
		.tint(.green)
		.controlSize(.large)
		.disabled(inFlight != nil || subscriptionState.isSubscribed)
		.testability(Testability.Button.paywallSubscribe)
		// In non-production builds the purchase runs against Apple's Sandbox (no real
		// charge); flag the button so testers know it's safe to tap (AIA-0354).
		.underConstructionBadge()
	}

	/// When the free trial ends and billing begins (acceptance criterion 9).
	///
	/// The precision here is the point, and it is not symmetrical. **Before** a purchase the app can
	/// only add the offer's period to today: the trial actually starts whenever the transaction
	/// completes, which may be minutes later after Ask-to-Buy, a password prompt or a pending
	/// approval — so the copy says "around", and says why. **After** the purchase the answer stops
	/// being a guess and comes from the transaction's own expiration date, so it is stated plainly.
	///
	/// A user who is **not** trial-eligible gets a date too, and it is "now" (AIA-0556). They used to
	/// get nothing, which was defensible while this screen was only ever reached voluntarily: the
	/// trial line was simply absent and the price stood on its own. It is not defensible at the hard
	/// wall. That user has just spent fourteen days of free access, arrives at a screen whose entire
	/// job is to state the offer, and — because they redeemed Apple's introductory offer at some
	/// point in the past — reads a price with nothing said about when it is taken. Every other reader
	/// of the same screen is told. The absence is not neutral there; it reads as a sentence that lost
	/// its second half, and the honest completion is that there is no free period left to wait
	/// through.
	///
	/// Silent for a subscriber past their trial, where the renewal date is `SubscriptionStatusView`'s
	/// job, not the paywall's — and silent until StoreKit has answered at all, so the two mutually
	/// exclusive claims can never trade places on screen.
	@ViewBuilder
	private func billingNote(for product: Product) -> some View {
		if subscriptionState.isSubscribed {
			if subscriptionState.isInTrial, let expiration = subscriptionState.currentExpirationDate {
				billingNoteText(L10n.Paywall.Billing.exact(
					expiration.formatted(date: .abbreviated, time: .omitted)
				))
			}
		} else if introOfferEligibility == true {
			if let estimate = Self.estimatedFirstBillingDate(for: product) {
				billingNoteText(L10n.Paywall.Billing.estimate(
					estimate.formatted(date: .abbreviated, time: .omitted)
				))
			}
		} else if introOfferEligibility == false, Self.hasFreeTrialOffer(product) {
			// The offer's *existence* is checked separately from this customer's eligibility for it.
			// StoreKit answers only the second question, and a product carrying no introductory offer
			// can report `false` for everyone — telling those users they have used up a trial that
			// was never on sale would be a plain untruth. Only the conjunction is safe to state.
			billingNoteText(L10n.Paywall.Billing.immediate)
		}
	}

	/// Whether the product ships an introductory **free trial** — as opposed to no introductory offer
	/// at all, or a paid-introductory one. The single question separating "this user spent the trial"
	/// from "there is no trial to spend".
	private static func hasFreeTrialOffer(_ product: Product) -> Bool {
		product.subscription?.introductoryOffer?.paymentMode == .freeTrial
	}

	private func billingNoteText(_ text: String) -> some View {
		Text(text)
			.font(.caption2)
			.foregroundStyle(.secondary)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
	}

	/// Today plus the introductory offer's period, or `nil` when the offer is not a free trial.
	///
	/// An estimate by construction — see ``billingNote(for:)`` for why it must be presented as one.
	/// A period unit Apple adds later returns `nil` rather than a wrong date: saying nothing is
	/// always better than naming the wrong day money moves.
	private static func estimatedFirstBillingDate(
		for product: Product,
		from now: Date = .now,
		calendar: Calendar = .current
	) -> Date? {
		guard let offer = product.subscription?.introductoryOffer,
			  offer.paymentMode == .freeTrial else { return nil }
		let component: Calendar.Component
		switch offer.period.unit {
		case .day: component = .day
		case .week: component = .weekOfYear
		case .month: component = .month
		case .year: component = .year
		@unknown default: return nil
		}
		return calendar.date(byAdding: component, value: offer.period.value, to: now)
	}

	/// The `Assets.xcassets` colorset backing ``continueAction``'s button. Named here rather than at
	/// the call site so the asset and its one consumer stay visibly paired.
	private static let continueButtonColorName = "ContinueButton"

	/// Apple's standard "Manage Subscriptions" deep link. The hardcoded literal always
	/// parses, so the force-unwrap cannot fail.
	// swiftlint:disable:next force_unwrapping
	private static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

	/// Apple's standard EULA, accepted as the Terms of Use when no custom one is provided.
	// swiftlint:disable:next force_unwrapping
	private static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

	/// "Free for 2 weeks, then $3.99 / month" when the product carries an introductory free-trial
	/// offer; `nil` otherwise. The trial length, the price and the period it recurs over all come
	/// from the product (configured in App Store Connect), so the copy follows whatever ships.
	///
	/// The second half states the term as well as the amount (AIA-0559): "then $3.99" leaves the
	/// most important question about a subscription — *how often* — unanswered on the one screen
	/// App Review 3.1.2 says must answer it.
	private static func freeTrialText(for product: Product) -> String? {
		guard let offer = product.subscription?.introductoryOffer,
			  offer.paymentMode == .freeTrial else { return nil }
		return L10n.Paywall.trialFormat(offer.period.localizedDescription, product.localizedPriceWithTerm)
	}

	/// ``freeTrialText(for:)`` for VoiceOver: same sentence, "per month" instead of a slash.
	/// Same format string, so the two can only ever differ in that one substitution.
	private static func spokenFreeTrialText(for product: Product) -> String? {
		guard let offer = product.subscription?.introductoryOffer,
			  offer.paymentMode == .freeTrial else { return nil }
		return L10n.Paywall.trialFormat(offer.period.localizedDescription, product.spokenPriceWithTerm)
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

/// Day 0 (AIA-0556): the window is being offered, and Continue is a real peer of Subscribe.
#Preview("Free access — offered") {
	PaywallView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		analytics: nil,
		continueAction: {},
		freeAccessOffer: .offered(days: 14, endsOn: .now.addingTimeInterval(14 * 24 * 60 * 60))
	)
}

/// The reminder: same screen, stating what is left instead of what is offered.
#Preview("Free access — reminder") {
	PaywallView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		analytics: nil,
		continueAction: {},
		freeAccessOffer: .remaining(days: 7, endsOn: .now.addingTimeInterval(7 * 24 * 60 * 60))
	)
}
#endif
