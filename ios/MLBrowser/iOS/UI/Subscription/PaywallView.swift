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

/// The paywall. Presented as the whole-app root gate (`SubscriptionGateView`) when the
/// signed-in user isn't subscribed. Reads products and entitlement from
/// ``SubscriptionState`` and drives purchase / restore intents.
///
/// AIA-0567 made this **one** screen instead of four. It used to serve the day-0 offer, the day-7
/// reminder, the hard wall and the Settings sheet, switching between them on whether a
/// `continueAction` and a `freeAccessOffer` were passed. The first two are now ``WelcomeView``, the
/// reminder is gone, and what is left is the screen that asks for money: the wall a spent window
/// leaves the user on, and the same offer reached voluntarily from Settings.
///
/// That collapse is why the optional inputs went with it. There is no Continue here — this screen is
/// only ever shown when there is nothing to continue *to* — so ``isDeadEnd`` reduces to
/// ``isRootGate``, and every App Review 3.1.2 disclosure is unconditional rather than gated on a
/// feature flag. **Acceptance criterion 8 of AIA-0556 is retired by that**: turning
/// `isFreeAccessPeriodEnabled` off no longer restores develop's paywall, so the flag is no longer a
/// revert path for this screen.
///
/// Two things still vary, and both are about telling a given reader only what is true of them.
/// ``addressesAReturningUser`` picks the voice — title, headline and description together, because
/// addressing a first-time arrival as a returning one in any single line reads as a form letter.
/// And ``isGettingFreeTrial`` picks which renewal disclosure appears: the standard text states that
/// payment is taken at confirmation, which is false for a trial customer and would sit a few points
/// from the note promising them nothing is charged.
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

	/// Whether a free-access window actually **ran out** to put the user here (AIA-0567).
	///
	/// Governs one sentence, and it is a sentence that must not be said to the wrong person.
	/// `FreeAccessAvailability.closed` covers both a window that expired and one that was never
	/// granted — for deciding whether to wall someone those are the same answer, which is why the
	/// gate collapses them — but "Your free access has ended" is only true of the first. A user who
	/// never had a window (payments on, free access off; or a build that ships the feature dark) is
	/// told what the subscription *is* instead of what they supposedly lost.
	///
	/// Defaults `false`, which is also what the Settings sheet wants: someone opening this
	/// voluntarily mid-window has lost nothing.
	var statesExpiredFreeAccess = false

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
	/// Identical to ``isRootGate`` since AIA-0567, and kept as its own name because the *question* is
	/// not the same one. It used to differ: the informational day-0 presentation was also a root gate
	/// but had the whole app one Continue away, so `continueAction` was what told them apart. That
	/// presentation is now ``WelcomeView`` and every remaining root presentation is a dead end.
	/// Only a dead end owes the user a way to get their data out of it — if a future presentation
	/// ever puts this screen over a reachable app again, this is the line that has to change, not the
	/// three call sites below.
	private var isDeadEnd: Bool { isRootGate }

	/// "Enjoying ML Browser?" — but only of someone who has actually used it (AIA-0567).
	///
	/// The engaged title is right for the two ways a user normally arrives here: a spent free window,
	/// or opening this from Settings. It is wrong for the one configuration where this screen is a
	/// brand-new install's *first* screen — payments on with free access off — where asking whether
	/// they are enjoying an app they have never opened reads as a form letter. That user gets the
	/// plain app name, which is what this screen said before the split.
	private var title: String {
		addressesAReturningUser ? L10n.Paywall.titleEngaged : L10n.Paywall.title
	}

	/// The sentence under the headline, in the voice this reader has earned.
	///
	/// Three cases, not two: a spent window is told it ended, a Settings visitor or a flag-off
	/// arrival is offered the subscription in the ordinary way, and a user who has never had access
	/// at all is not told to "keep using" something they have not started.
	private var description: String {
		if statesExpiredFreeAccess { return L10n.Paywall.expired }
		return addressesAReturningUser ? L10n.Paywall.pitch : L10n.Paywall.pitchFirstMeeting
	}

	/// Whether this screen is talking to somebody who has actually used the app.
	///
	/// True for the two ordinary arrivals — a spent free window, or opening this from Settings — and
	/// false in exactly one configuration: payments on with free access off, where this screen is a
	/// brand-new install's *first*. Everything written in the returning-user voice keys off this, not
	/// just the title: an earlier version made only the title conditional and left the headline and
	/// the description addressing a user who had never opened the app, which fixed a third of the
	/// problem and documented it as if it were the whole.
	private var addressesAReturningUser: Bool {
		statesExpiredFreeAccess || isRootGate == false
	}

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
						Text(title)
							.font(.title).bold()
							.multilineTextAlignment(.center)
						Text(addressesAReturningUser ? L10n.Paywall.headline : L10n.Paywall.headlineFirstMeeting)
							.font(.headline)
							.multilineTextAlignment(.center)
						Text(description)
							.font(.body)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding(.horizontal, 32)

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
		} else {
			// Empty product list: App Store Connect not configured yet, the local
			// .storekit file isn't wired into the scheme, or the mock path. Degrade
			// gracefully rather than showing a dead Subscribe button.
			Text(L10n.Paywall.unavailable)
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}

		// Where the money goes, once, in the words the user will see on their statement. Rendered
		// under the action rather than in the card because it answers the question the button
		// raises — "and then what" — and reads as reassurance there rather than as terms.
		Text(L10n.Paywall.cancelFooter)
			.font(.footnote)
			.foregroundStyle(.secondary)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)

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
			// A text action matching Manage Subscription visually. Opacity + overlay (not an
			// if/else swap) keeps its footprint stable while the restore is in flight.
			Text(L10n.Paywall.restore)
				.font(.footnote)
				.opacity(inFlight == .restore ? 0 : 1)
				.overlay { if inFlight == .restore { ProgressView() } }
		}
		.buttonStyle(.plain)
		.foregroundStyle(.tint)
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

	/// Whether *this* viewer is actually getting a free trial, and so must not be told that payment
	/// is taken at confirmation (AIA-0567).
	///
	/// The same conjunction the button label and the billing note use, and for the same reason:
	/// StoreKit's eligibility answer alone is not enough, because a product carrying no introductory
	/// offer reports every customer ineligible.
	private var isGettingFreeTrial: Bool {
		guard introOfferEligibility == true, let product = subscriptionState.products.first else { return false }
		return Self.hasFreeTrialOffer(product)
	}

	/// Auto-renewable subscription disclosures required on the purchase screen
	/// (App Review Guideline 3.1.2): renewal terms + Terms of Use + Privacy Policy.
	///
	/// The renewal sentence has two forms, and picking the wrong one puts two contradictory claims
	/// about money a few points apart on the screen App Review reads most carefully. The standard
	/// text says payment is charged **at confirmation**, which is true — unless the customer is
	/// getting a free trial, in which case the note under the button says nothing is charged during
	/// it. Both were rendered together before this was split (AIA-0567), for exactly the population
	/// the trial copy exists to reassure.
	@ViewBuilder
	private var legalFooter: some View {
		VStack(spacing: 8) {
			Text(isGettingFreeTrial ? L10n.Paywall.disclosureTrial : L10n.Paywall.disclosure)
				.font(.footnote)
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

			// What the subscription includes, stated concretely (AIA-0567). The ASC description
			// above says what it *is*; these say what you get, which is the question a user at a
			// wall is actually asking. Deliberately additive to the ASC line rather than a
			// replacement for it — App Review 3.1.2 wants the store's own description of the
			// service on the sign-up screen, and four in-app bullets are not that.
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Self.benefits, id: \.self) { benefit in
					Label(benefit, systemImage: "checkmark")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(.top, 4)
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
			Text(purchaseButtonTitle(for: product))
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

		billingNote(for: product)
	}

	/// "Start 1 Month Free Trial" for a user who will actually get one; "Subscribe" for everyone else.
	///
	/// Both halves of the condition are load-bearing and they answer different questions.
	/// `introOfferEligibility` is StoreKit's answer about *this Apple Account* — a returning user who
	/// already spent the trial is charged at once, and promising them a free one is the kind of copy
	/// that gets a build rejected. ``hasFreeTrialOffer`` asks whether the product carries a trial at
	/// all, because a product with no introductory offer reports ineligible for *everyone*, and
	/// without this the label would be right by accident rather than by construction.
	///
	/// The period comes from the offer, never a literal: the ticket's "Start 14-Day Free Trial"
	/// hardcodes a length that App Store Connect owns and can change without a release.
	private func purchaseButtonTitle(for product: Product) -> String {
		guard introOfferEligibility == true,
			  Self.hasFreeTrialOffer(product),
			  let period = product.subscription?.introductoryOffer?.period.localizedDescription
		else { return L10n.Paywall.subscribe }
		return L10n.Paywall.startTrial(period)
	}

	/// When money actually starts moving, under the button that starts it.
	///
	/// The wording is **transaction-relative on purpose** (AIA-0567). The obvious copy — "billing
	/// starts in 14 days" — is wrong twice over. It contradicts ``L10n/Paywall/disclosure`` rendered
	/// a few points below it, which states that payment is charged *at confirmation*; a screen that
	/// says both is a screen App Review reads twice. And it is not true: the trial starts when the
	/// transaction completes, which after Ask-to-Buy or a pending approval can be days later, so a
	/// countdown from today names a date the app cannot honour. Anchoring to "after your purchase
	/// completes" keeps the plain-language promise the ticket asked for and stays true whenever the
	/// purchase lands.
	///
	/// A user who is **not** trial-eligible is told instead that billing starts at once (AIA-0556).
	/// That absence would not be neutral here: they have just spent their free window, arrive at a
	/// screen whose whole job is to state the offer, and would otherwise read a price with nothing
	/// said about when it is taken while every other reader of the same screen is told.
	///
	/// Silent until StoreKit has answered at all, so the two mutually exclusive claims can never
	/// trade places on screen — and silent for a subscriber, whose renewal date is
	/// `SubscriptionStatusView`'s job, not the paywall's.
	@ViewBuilder
	private func billingNote(for product: Product) -> some View {
		if subscriptionState.isSubscribed {
			EmptyView()
		} else if introOfferEligibility == true, Self.hasFreeTrialOffer(product),
				  let period = product.subscription?.introductoryOffer?.period.localizedDescription {
			billingNoteText(L10n.Paywall.trialSupport(period))
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
			.font(.footnote)
			.foregroundStyle(.secondary)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
	}

	/// What the subscription includes (AIA-0567), in the order the ticket specified.
	///
	/// Static and localized rather than derived: these are product claims, not facts StoreKit knows.
	/// Two of them — "all current and future features" and "regular updates" — are commitments, and
	/// they live here so there is one place to change them if the product's shape ever stops
	/// honouring them.
	private static var benefits: [String] {
		[
			L10n.Paywall.Benefit.unlimited,
			L10n.Paywall.Benefit.features,
			L10n.Paywall.Benefit.updates,
			L10n.Paywall.Benefit.cancel
		]
	}

	/// Apple's standard "Manage Subscriptions" deep link. The hardcoded literal always
	/// parses, so the force-unwrap cannot fail.
	// swiftlint:disable:next force_unwrapping
	private static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

	/// Apple's standard EULA, accepted as the Terms of Use when no custom one is provided.
	// swiftlint:disable:next force_unwrapping
	private static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

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

/// The hard wall after a window ran out (AIA-0567) — the only presentation that says so.
#Preview("Expired free access") {
	PaywallView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		analytics: nil,
		isRootGate: true,
		statesExpiredFreeAccess: true
	)
}

/// The same wall for someone who never had a window — payments on, free access off. Proves the
/// title and the description both stay neutral rather than claiming a loss that never happened.
#Preview("Wall — no window was ever granted") {
	PaywallView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		analytics: nil,
		isRootGate: true
	)
}
#endif
