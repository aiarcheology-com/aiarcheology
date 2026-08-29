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
		case .restoreRecommended:
			// The one outcome that must break the silence a cancel normally earns: the customer was
			// just told by Apple that a subscription exists and then handed back a Subscribe button.
			// Restore Purchases is on this screen — the alert's whole job is to name it.
			return .init(
				title: L10n.Paywall.RestoreRecommended.title,
				message: L10n.Paywall.RestoreRecommended.message
			)
		case .failed:
			return .init(title: L10n.Alert.Error.title, message: L10n.Paywall.Failed.message)
		}
	}

	/// What to say once a restore attempt finishes. `nil` means stay quiet.
	///
	/// `.restored` needs no alert: the entitlement lands in published state and the gate
	/// re-renders, which is the answer. `.nothingToRestore` is **not** an error — the store
	/// answered correctly and the Apple Account signed in here owns nothing.
	///
	/// That last word is why this copy is as long as it is (AIA-0525). Entitlement is scoped to
	/// the **Apple Account**, identity to the app account, and the two need not be the same
	/// person's — so this alert is what a user sees who has already paid on another Apple Account
	/// and is about to be asked for money a second time. It is the last screen before that
	/// happens, and therefore the only place a double charge can be prevented rather than
	/// refunded. It says so explicitly.
	///
	/// It states the rule, never a tap route: "Settings → your name → Media & Purchases" is wrong
	/// on iOS-on-Mac, Apple renames it, and no translator can verify it. Exact paths belong in the
	/// support macro, where they change without a release.
	static func forRestore(_ outcome: RestoreOutcome) -> SubscriptionNotice? {
		switch outcome {
		case .restored:
			return nil
		case .nothingToRestore:
			return .init(title: L10n.Paywall.RestoreEmpty.title,
						 message: L10n.Paywall.RestoreEmpty.messageAppleAccount)
		case .failed:
			return .init(title: L10n.Alert.Error.title, message: L10n.Paywall.RestoreFailed.message)
		}
	}

}

/// A hairline outline for the paywall's two secondary actions — Restore Purchases and Manage
/// Subscription.
///
/// Deliberately **not** `.bordered`: a filled capsule would compete with Subscribe, which is the
/// only action this screen wants tapped, and the screen already spends its one filled control on
/// it. Left bare, though, both read as captions rather than controls — which is exactly how they
/// looked on the App Review screenshot. A hairline keeps them recognisably tappable and still
/// visually subordinate, and the padding it needs doubles the touch target.
///
/// Both fill the content width rather than hugging their labels. Hugging made the two capsules
/// visibly different sizes — "Manage Subscription" is a longer word pair than "Restore Purchases" —
/// which reads as a mistake rather than a hierarchy. Filling also aligns them with Subscribe and
/// with the screen's other bordered controls, so the equality holds by construction instead of by
/// the two labels happening to be a similar length in a given locale.
///
/// `Color.secondary` rather than a literal: this app hardcodes no colours, and the outline has to
/// stay legible in both appearances. Deliberately not the hierarchical `.tertiary`, which resolves
/// against the *foreground* style — Restore sets `.foregroundStyle(.tint)` and Manage is a `Link`,
/// so the same modifier would have drawn two different colours.
private struct PaywallOutlinedAction: ViewModifier {
	func body(content: Content) -> some View {
		content
			.frame(maxWidth: .infinity)
			.padding(.vertical, 10)
			.overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1))
	}
}

private extension View {
	func paywallOutlinedAction() -> some View { modifier(PaywallOutlinedAction()) }
}

/// What a tap on Subscribe must actually do (AIA-0623).
///
/// The app-managed free window and Apple's introductory trial **do not stack**, and an intro offer
/// cannot be deferred — it begins the moment the subscription starts. So a user who converts on day
/// 5 of a 14-day window gets 19 free days and one who waits gets 28, for identical access. Nothing
/// on the screen said so, which meant the app quietly charged its most willing customers nine days
/// sooner than its most patient ones.
///
/// Hooked to the **purchase**, not to any presentation of the paywall, and that is the whole design.
/// Every route to spending money ends at one button, so covering the button covers every route by
/// construction — including the next one somebody adds. A presentation hook has to be repeated per
/// entry point and silently misses it.
///
/// Keyed on the window alone, never on trial eligibility. A user with no intro offer is charged
/// *immediately*, so their loss is larger, not smaller; keying this on `hasFreeTrialIntroOffer`
/// would skip the worst case. It is self-limiting for the same reason it is simple: once the window
/// is gone there are no days to count, so the hard wall behaves exactly as it did before.
///
/// Extracted as a value rather than written inline in the button for the reason ``RootGateDisplay``
/// was: a decision about money is worth stating once, in a place a test can reach without a
/// simulator — and the paywall's Subscribe button provably cannot be driven by the UI suite (the
/// mock provider exposes no `Product`).
enum PaywallPurchaseIntent: Equatable {
	/// Buy now. No window is open, so there is nothing to forfeit.
	case purchase

	/// Ask first: `remainingDays` of app-managed free access are on the table.
	case confirmForfeitingFreeAccess(remainingDays: Int)

	/// - Parameter freeAccessDaysRemaining: whole calendar days left in the open window, or `nil`
	///   when none is open. Must come from ``FreeAccessState/windowDaysRemaining`` — i.e. from the
	///   window's phase — and never from a fresh count against the end date; see that property for
	///   why the two can disagree.
	static func resolve(freeAccessDaysRemaining: Int?) -> PaywallPurchaseIntent {
		guard let days = freeAccessDaysRemaining, days > 0 else { return .purchase }
		return .confirmForfeitingFreeAccess(remainingDays: days)
	}
}

/// What the delete-account confirmation on the hard wall must say, and offer (AIA-0779).
///
/// Deleting the account purges the *cloud* copy of the findings (`AuthState.deleteAccount` →
/// `purgeCloudData`) and leaves the device copy alone. That is the one moment a user needs told,
/// because the screen they are standing on is the wall: Settings — and with it the findings
/// inventory — is behind the gate, and someone who believes deletion took their work with it has
/// no way from here to find out otherwise. The escape hatch to export already exists (AIA-0556);
/// what was missing is that the delete dialog never mentioned it, which is what the reporter hit.
///
/// A value, not an `if` inside the dialog, for the reason ``PaywallPurchaseIntent`` is one: the
/// confirmation cannot be driven by the UI suite in the state that matters — the UI-testing launch
/// path wipes the Caches store, so `hasAnyFinding()` is false there and the interesting branch is
/// unreachable — and a decision about someone's data is worth stating where a test can reach it.
enum PaywallAccountDeletionPrompt: Equatable {
	/// Nothing is saved on this device. Warn about billing only, exactly as before AIA-0779.
	case billingOnly

	/// This device still holds findings: say so, and offer to export them before deleting.
	case billingAndFindings

	/// - Parameter hasSavedFindings: whether this install has anything saved — the same answer the
	///   findings escape hatch is shown on, read once on appear.
	static func resolve(hasSavedFindings: Bool) -> PaywallAccountDeletionPrompt {
		hasSavedFindings ? .billingAndFindings : .billingOnly
	}

	/// Whether the confirmation offers Export First… beside the destructive action.
	var offersFindingsExport: Bool { self == .billingAndFindings }

	/// The body of the confirmation. Both forms carry the billing warning AIA-0528 added.
	///
	/// **Composed, not a second whole-message key.** The billing warning ships in every locale the
	/// app does; a new key carrying both sentences would have been English-only until translators
	/// caught up, silently downgrading a warning App Review reads — for the readers who need it
	/// most, since only a user *with* findings would have seen it. Appending keeps the translated
	/// half translated and confines the untranslated text to the sentence that is genuinely new.
	var message: String {
		switch self {
		case .billingOnly:
			return L10n.Auth.Account.Delete.messageBilling
		case .billingAndFindings:
			return L10n.Auth.Account.Delete.messageBilling + "\n\n" + L10n.Auth.Account.Delete.findingsNote
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
/// And ``trialEligibility`` picks which renewal disclosure appears: the standard text states that
/// payment is taken at confirmation, which is false for a trial customer and would sit a few points
/// from the note promising them nothing is charged. It is three-valued, so neither claim is made
/// while StoreKit is still answering.
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

	/// Whole calendar days left in the app-managed free window, read **at the moment of the tap**
	/// (AIA-0623). `nil` when no window is open.
	///
	/// A closure and not a value, deliberately. The count changes while this screen is up — the
	/// window can run out under an open sheet, and `FreeAccessState` publishes nothing when it does
	/// (`windowDaysRemaining` is computed) — so a value captured at construction could tell someone
	/// they still have three free days minutes after the gate stopped believing it. The sibling
	/// `SettingsForm.freeAccessEndsOn` may be a plain value precisely because *it* is frozen at
	/// grant; this is not. `continueAction` crosses the same boundary the same way.
	///
	/// **No default, on purpose.** An omittable `= nil` is how this ships dead: a future
	/// presentation that forgets the argument compiles, renders a paywall that silently forfeits
	/// the window, and passes every test in the suite. Without a default, the memberwise
	/// initialiser makes every call site state its answer.
	let freeAccessDaysRemaining: () -> Int?

	@Environment(\.dismiss) private var dismiss

	/// Real vs. mock auth from the composition root (AIA-0385); forwarded into the sign-in sheet.
	@Environment(\.usesRealAuth) private var usesRealAuth

	/// Opens Apple's subscription management page from inside the delete-account dialog, where a
	/// `Link` cannot be used (see the dialog below).
	@Environment(\.openURL) private var openURL

	/// The purchase/restore round-trip currently in flight, or `nil` when idle. Knowing
	/// *which* action runs (not just a Bool) lets the tapped button show its own spinner —
	/// without it the disabled buttons read as a frozen app while StoreKit takes seconds
	/// to present its sheet (AIA-0448).
	private enum InFlightAction {
		case purchase
		case restore
	}
	@State private var inFlight: InFlightAction?

	/// A purchase waiting on the free-days confirmation: what it would buy, what it would cost in
	/// days the user already has, and which of the two truths about money applies to them
	/// (AIA-0623).
	///
	/// All three are carried rather than re-read when the user answers. `subscriptionState.products`
	/// is refreshed asynchronously, so re-reading `.first` could buy a different product from the one
	/// the button was labelled for; the day count is the one the *decision* was made on, so the
	/// alert can never show a number the branch did not use; and ``getsTrial`` is read at the tap for
	/// the same reason, while the button's `.disabled` still guarantees StoreKit has answered.
	private struct PendingForfeitPurchase {
		let product: Product
		let remainingDays: Int

		/// Whether this viewer is actually getting Apple's introductory trial.
		///
		/// The alert says what subscribing *now* starts, and for these two populations that is not
		/// the same sentence: a trial customer's trial begins at purchase, and everyone else is
		/// charged at once. Telling the second group their "trial" starts immediately would promise
		/// them something they will not get, on the screen App Review reads most carefully — and
		/// they are precisely the population the confirmation exists for, because being charged at
		/// once is the *larger* loss, not the smaller one.
		let getsTrial: Bool
	}

	/// The purchase the free-days confirmation is holding, or `nil` at every other moment.
	@State private var pendingPurchase: PendingForfeitPurchase?

	/// Presents the contextual sign-in sheet from the root paywall (AIA-0536).
	@State private var showSignIn = false

	/// True while a StoreKit round-trip owns this screen. Consulted inside each action rather than
	/// via `.disabled` on its siblings; see ``SubscriptionStatusView/isBusy`` for why (AIA-0448).
	private var isBusy: Bool { inFlight != nil }

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
	///
	/// Governs the findings button only. The delete-account confirmation takes its own fresh count
	/// at the tap — see ``accountDeletionPrompt`` — because that dialog can be reached long after
	/// this was answered, and by then sync may have imported findings this does not know about.
	@State private var hasSavedFindings = false

	/// Drives the Export / Delete / Cancel confirmation for the saved findings.
	@State private var showRemoveFindings = false

	/// What the delete-account confirmation says and offers, frozen when it opens (AIA-0779).
	///
	/// Resolved at the tap from a **fresh** count, not from the answer `onAppear` happened to get:
	/// findings sync runs outside the subscription gate and can import cloud findings while this
	/// screen is up, so an appear-time `false` can be stale by the time somebody reaches for Delete
	/// Account — and being told nothing about findings that exist is the whole of AIA-0779.
	///
	/// Frozen rather than recomputed per render for the reason the dialog's other inputs are: the
	/// message and the actions must describe the same install, and a count landing between the two
	/// would let the dialog offer an export it never mentioned, or mention one it never offered.
	@State private var accountDeletionPrompt: PaywallAccountDeletionPrompt = .billingOnly

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
			// A way out, and **only** where one exists (AIA-0616).
			//
			// Presented from Settings during the free-access window, this screen is an offer: the
			// user still has days left and can simply close it. Without a visible control it read as
			// a wall, because the only exit was an undiscoverable swipe — and a screen that looks
			// like "subscribe or nothing" when it is not costs a conversion at best and reads as a
			// dark pattern at worst, on precisely the screen App Review scrutinises.
			//
			// Keyed on ``isDeadEnd``, so the root gate — where there genuinely is nothing to go back
			// to — is untouched and cannot be dismissed into a blank app. That is the same question
			// the findings escape hatch asks, and it is the reason the property exists rather than
			// each site testing ``isRootGate`` for itself.
			.overlay(alignment: .topTrailing) {
				if isDeadEnd.not {
					Button {
						dismiss()
					} label: {
						// The word, not an ✕. A glyph asks the reader to interpret it, and this is the
						// one screen where a user who misreads the exit concludes they have to pay.
						// `L10n.Common.dismiss` already ships in all 17 locales, so saying it costs
						// nothing — and with real text the label *is* the accessibility label, which is
						// why no `.accessibilityLabel` is set: adding one would make VoiceOver say it
						// twice.
						Text(L10n.Common.dismiss)
							.font(.body.weight(.semibold))
							.padding(.horizontal, 14)
							// 44×44 is Apple's minimum touch target, set explicitly rather than reached
							// by adding up padding — padding arithmetic is exactly what regresses the
							// next time someone nudges the insets.
							.frame(minWidth: 44, minHeight: 44)
							.background(.thinMaterial, in: Capsule())
					}
					.buttonStyle(.plain)
					// The same blue as Restore, Manage and the legal links: a control, not a caption.
					// The paywall scrolls *under* this overlay, so the material backing is load-bearing
					// rather than decorative — without it the word sits on top of moving body text.
					.tint(Self.interactiveTint)
					.foregroundStyle(Self.interactiveTint)
					.padding(.top, 8)
					.padding(.trailing, 16)
					.testability(Testability.Button.paywallDismiss)
				}
			}
			// The free days a purchase would forfeit, said before the money moves (AIA-0623).
			//
			// The app-managed window and Apple's introductory trial do not stack and the trial cannot
			// be deferred, so subscribing on day 5 of 14 buys nineteen free days where waiting would
			// have bought twenty-eight. Nothing on this screen said so, which meant the app charged
			// its most willing customers soonest.
			//
			// An **alert**, not a `.confirmationDialog`, and on this screen that is a behavioural
			// choice rather than a stylistic one. Two reasons, and the other two dialogs below can
			// hit neither.
			//
			// This is the only confirmation on this screen reachable from the **Settings sheet** —
			// both others are root-gate only. `SettingsView.resetSection` already records what
			// happens there: its Remove Findings confirmation is an `.alert` precisely because a
			// `.confirmationDialog` *did not present* from that sheet-hosted `Form` (AIA-0303). An
			// action sheet here would have been the one shape with a known failure on the one route
			// that is new.
			//
			// And on iPad a `.confirmationDialog` presents as a popover, from which the system
			// **omits cancel-role actions entirely** — so the safe choice, "Keep My Free Days", would
			// not have been rendered for iPad users at all, leaving them to infer that tapping
			// outside kept their days. An alert renders both actions on every device family, which is
			// what a decision about money needs.
			//
			// **Attached to the ScrollView, not alongside `notice` on the `GeometryReader`**, and
			// that placement is load-bearing: SwiftUI does not promise to honour two `.alert`
			// modifiers chained onto the *same* view, which is the reason `notice` is a single alert
			// carrying three different messages (AIA-0376). One level in is a different view, so both
			// presentations are the only alert their own view owns. Being inside the `GeometryReader`
			// changes nothing about what is presented — an alert is presented by the enclosing
			// controller, not laid out in place.
			//
			// Two independent explicit choices, the same shape as the two dialogs below. "Inform, do
			// not obstruct": Subscribe Anyway is a plain default action, not a destructive one —
			// anything more insistent about a purchase the user is entitled to make is an App Review
			// risk, and this alert's job is to tell them what it costs, not to argue.
			.alert(
				pendingPurchase.map { L10n.Paywall.KeepFreeAccess.titleNoPaymentNeeded($0.remainingDays) } ?? "",
				isPresented: .init(
					get: { pendingPurchase != nil },
					set: { if $0 == false { pendingPurchase = nil } }
				),
				presenting: pendingPurchase
			) { pending in
				// Neither action clears `pendingPurchase` itself: the `isPresented` setter above is
				// the one place that does, which is also how the `Bool`-bound dialogs on this screen
				// behave. Clearing it in both places would be a second writer for no gain, and the
				// title is evaluated from that state — unlike the actions and message, which
				// `presenting:` keeps alive through the dismissal — so a redundant clear can only
				// risk emptying the title early, never help.
				Button(L10n.Paywall.KeepFreeAccess.subscribeAnyway) {
					startPurchase(pending.product)
				}
				.testability(Testability.Button.paywallSubscribeAnyway)

				// `.cancel`, so it is the emphasised, escape-mapped choice and dismissal defaults to
				// keeping the days rather than spending them.
				Button(L10n.Paywall.KeepFreeAccess.keep, role: .cancel) {
					// The only way to tell "backed out at our alert" from "cancelled Apple's sheet":
					// both leave `subscribeTapped` with no `subscriptionActivated` behind it. Without
					// this event a conversion-affecting screen ships with no way to see what it cost.
					analytics?.track(.freeAccessKeepDaysTapped)
				}
				.testability(Testability.Button.paywallKeepFreeAccess)
			} message: { pending in
				// The one sentence that has to be true of *this* reader. `billingNote(for:)` under
				// the button already draws the same distinction, and it is drawn again here rather
				// than deferred to it, because the alert covers that note while it is up — a user
				// reading "your trial" here who is in fact charged at once would have no way to learn
				// otherwise before tapping.
				//
				// Both strings are anchored to the purchase *completing*, never to "now", which is
				// the rule ``billingNote(for:)`` states and the reason it states it: after Ask-to-Buy
				// or a pending approval the trial and the billing both begin whenever the transaction
				// lands, which can be days later — and `.pending` is a reachable outcome of the very
				// button this alert guards (see ``SubscriptionNotice/forPurchase(_:)``).
				Text(pending.getsTrial
					 ? L10n.Paywall.KeepFreeAccess.messageWithTrial
					 : L10n.Paywall.KeepFreeAccess.messageNoTrial)
			}
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
		// Deleting the Clerk account does **not** stop Apple billing (AIA-0528), and the copy used
		// to say only that deletion was permanent — leaving someone who believed the relationship
		// was over to keep being charged.
		//
		// The warning is unconditional and hedged ("if you have a subscription") rather than gated
		// on `subscriptionState.isSubscribed`, which would render it never: `RootGateDisplay.resolve`
		// returns `.content` as soon as a user is entitled, and Settings presents this screen only
		// in the not-subscribed branch, so `isSubscribed` is false here in every reachable state.
		// A conditional would also have hidden the warning from precisely the person AIA-0525
		// describes — paid on another Apple Account, and therefore reading as unsubscribed here.
		//
		// Manage Subscription is `.default`, never `.cancel`: a second cancel role would collide
		// with the Cancel below. It dismisses without deleting, which is the same "two independent
		// explicit choices" shape as the findings dialog above.
		//
		// A `Button` opening the URL, **not** a `Link`, and the reason is a contract rather than a
		// bug. Apple documents that on iOS a confirmation dialog supports only controls whose label
		// is `Text`, and that passing any other view "results in the content being omitted".
		//
		// Measured, so the comment does not overclaim: a `Link` here *does* currently render and is
		// found by the UI test. But rendering is the easy half — a `Link` in an action sheet also
		// has to route its tap through a bridged `UIAlertAction`, which the documentation does not
		// promise either, and a tap that silently does nothing cannot be tested for without leaving
		// the app. So this trades an undocumented behaviour that happens to work for the documented
		// one, on the screen where the failure would ship a billing warning pointing at nothing.
		//
		// The UI test asserts the action is present; it does **not** discriminate `Link` from
		// `Button` (both pass), and is not claimed to.
		.confirmationDialog(
			L10n.Auth.Account.Delete.title,
			isPresented: $showDeleteConfirmation,
			titleVisibility: .visible
		) {
			// Offered before the destructive action, and only when there is something to export
			// (AIA-0779). Exporting never deletes — it is the same independent explicit choice the
			// findings dialog above is built on, and the same `exportFindings()`: the share sheet is
			// attached to the paywall itself, so it outlives this dialog's dismissal.
			if accountDeletionPrompt.offersFindingsExport {
				Button(L10n.Settings.Reset.RemoveFindings.export) {
					exportFindings()
				}
				.testability(Testability.Button.paywallDeleteAccountExportFindings)
			}

			Button(L10n.Paywall.manage) {
				openURL(.appleManageSubscriptions)
			}
			.testability(Testability.Button.paywallDeleteAccountManage)

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
			Text(accountDeletionPrompt.message)
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
				.paywallOutlinedAction()
		}
		.buttonStyle(.plain)
		.foregroundStyle(.tint)
		// See ``Self.interactiveTint``: the app's AccentColor is a neutral grey, and `.tint`
		// resolves to it, which is what drew this control at ~2.1:1 on white.
		.tint(Self.interactiveTint)
		.disabled(inFlight != nil)
		.testability(Testability.Button.paywallRestore)

		// Manage existing subscription (cancel / change plan). Always available so a
		// subscriber can reach Apple's management screen from here.
		Link(L10n.Paywall.manage, destination: .appleManageSubscriptions)
			.font(.footnote)
			.tint(Self.interactiveTint)
			.paywallOutlinedAction()
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
				// the no-structural-churn rule of AIA-0448, because the share sheet is presented
				// from this screen and structural churn on a presenting view wedges its dismissal
				// on iOS-on-Mac.
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
			// Tinted like Restore and Manage, for the reason given on ``interactiveTint``: a
			// `.bordered` button with no tint resolves its label to the app's grey AccentColor,
			// which on this screen reads as *disabled* rather than as a control (AIA-0779).
			.tint(Self.interactiveTint)
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
					.tint(Self.interactiveTint)
					.testability(Testability.Button.paywallSignOut)

					Button(role: .destructive) {
						// Counted here, not read from `onAppear` — see ``accountDeletionPrompt``.
						//
						// Into a local, deliberately: writing `hasSavedFindings` would insert or
						// remove the findings button in the same transaction that presents this
						// dialog, and structural churn on a presenting view is what wedges the
						// share sheet on iOS-on-Mac (AIA-0448). Only the dialog needs the fresh
						// answer; the button keeps the appear-time one it always had.
						accountDeletionPrompt = .resolve(
							hasSavedFindings: findingRepository?.hasAnyFinding() == true
						)
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
				.tint(Self.interactiveTint)
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
		// Two entry points reach this now — the findings dialog and the delete-account confirmation
		// (AIA-0779) — so the re-entrancy guard moves here from the button that used to be the only
		// caller. A second build landing under the first would reassign `findingsSharePayload`
		// mid-presentation, which is the wedge AIA-0402/0448 exist to avoid.
		guard isExportingFindings.not, let findingRepository else { return }
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

	/// Whether *this* viewer is getting a free trial — with "not yet known" kept distinct from "no".
	///
	/// Three-valued for the reason the original trial line was: `introOfferEligibility` is `nil`
	/// until StoreKit answers, and collapsing that to `false` puts the wrong claim about money on
	/// screen and then swaps it. On this screen that means an eligible customer briefly reads
	/// "payment is charged at confirmation" under a button labelled Subscribe, and both change
	/// under them a moment later. Every consumer below waits instead.
	///
	/// Both halves of the resolved answer are load-bearing: StoreKit's eligibility alone is not
	/// enough, because a product carrying no introductory offer reports every customer ineligible.
	private enum TrialEligibility: Equatable {
		case unresolved
		case gettingTrial
		case noTrial
	}

	private var trialEligibility: TrialEligibility {
		guard let product = subscriptionState.products.first else { return .unresolved }
		guard product.hasFreeTrialIntroOffer else { return .noTrial }
		switch introOfferEligibility {
		case .none: return .unresolved
		case .some(true): return .gettingTrial
		case .some(false): return .noTrial
		}
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
			// Silent while eligibility is unresolved rather than guessing. Nothing can be bought in
			// that instant either — the purchase button is disabled — so no renewal disclosure is
			// owed yet, and stating the wrong one and correcting it under the reader is worse than
			// stating the right one a moment later.
			if trialEligibility != .unresolved {
				Text(trialEligibility == .gettingTrial ? L10n.Paywall.disclosureTrial : L10n.Paywall.disclosure)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					// Required disclosure (App Review 3.1.2) must show in full — let it claim its
					// natural height so it wraps instead of truncating under vertical compression.
					.fixedSize(horizontal: false, vertical: true)
			}

			// Underlined, and tinted away from the grey AccentColor — see ``Self.interactiveTint``.
			// These two are the only controls on this screen whose sole "I am a link" signal was
			// colour: Restore and Manage carry a capsule, these are bare `.caption2` text. Schedule
			// 2 §3.8(b) requires both to be *functional links accessible within* the app, so the
			// underline matters independently of the contrast fix — it survives any future palette
			// change, and it answers a reviewer's "is this a link?" without relying on hue.
			HStack(spacing: 16) {
				Link(destination: Self.termsOfUseURL) {
					Text(L10n.Paywall.terms).underline()
				}
				Button {
					showPrivacy = true
				} label: {
					Text(L10n.About.privacyPolicy).underline()
				}
				.testability(Testability.Button.paywallPrivacyPolicy)
			}
			.font(.caption2)
			.tint(Self.interactiveTint)
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
			// `pendingPurchase` is part of the guard, not just `isBusy` (Copilot, PR #625). The
			// confirm branch below never sets `inFlight`, so between the tap that raises the alert
			// and the alert actually covering the screen `isBusy` is still false — a second tap runs
			// this whole body again, reports both events a second time and reassigns the pending
			// purchase. The overcount lands on `freeAccessConfirmShown`, whose ratio to
			// `freeAccessKeepDaysTapped` is the only evidence that the alert presented at all, so it
			// is precisely the counter that must not be inflated by a double tap.
			guard isBusy.not, pendingPurchase == nil else { return }
			// Reported on the *tap*, before the branch, so the funnel keeps the meaning it has always
			// had: somebody asked to subscribe. Moving it behind the confirmation would silently
			// redefine the stage and break comparison with every build before this one — and backing
			// out at our alert is no different, as a funnel event, from cancelling Apple's sheet,
			// which has always counted. `freeAccessKeepDaysTapped` is what distinguishes the two.
			analytics?.track(.subscribeTapped)
			switch PaywallPurchaseIntent.resolve(freeAccessDaysRemaining: freeAccessDaysRemaining()) {
			case .purchase:
				startPurchase(product)
			case let .confirmForfeitingFreeAccess(remainingDays):
				// `trialEligibility` cannot be `.unresolved` here: this button is `.disabled` until
				// StoreKit has answered, so the tap that reaches this line has a real answer behind
				// it and the alert never has to hedge about money.
				pendingPurchase = .init(
					product: product,
					remainingDays: remainingDays,
					getsTrial: trialEligibility == .gettingTrial
				)
				// Reported on the *raise*, not on the render — nothing can observe whether a
				// confirmation actually appeared. That is the point: this is the one alert in the
				// app no automated test can drive, so raises with no answer behind them are the only
				// available signature of one that failed to present.
				analytics?.track(.freeAccessConfirmShown)
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
		// Also disabled while eligibility is unresolved: for that instant the label cannot say
		// truthfully what the tap buys, and a purchase started from a mislabelled button is the one
		// mistake on this screen that costs the user money.
		.disabled(inFlight != nil || subscriptionState.isSubscribed || trialEligibility == .unresolved)
		.testability(Testability.Button.paywallSubscribe)
		// In non-production builds the purchase runs against Apple's Sandbox (no real
		// charge); flag the button so testers know it's safe to tap (AIA-0354).
		.underConstructionBadge()

		billingNote(for: product)
	}

	/// Commits the purchase. The single place money is ever asked for (AIA-0623).
	///
	/// Lifted out of the button verbatim so the direct tap and "Subscribe Anyway" reach StoreKit
	/// through exactly the same code, rather than through two copies that can drift.
	///
	/// It re-checks its own preconditions instead of trusting the caller's, because one of the two
	/// callers is a confirmation alert: an unbounded amount of time passes between the tap that
	/// raised it and the tap that answers it, and in that window a restore, an Ask-to-Buy approval
	/// arriving on `Transaction.updates`, or a second tap can all have landed. The button's
	/// `.disabled` cannot help here — the alert's buttons are not it.
	private func startPurchase(_ product: Product) {
		guard isBusy.not, subscriptionState.isSubscribed == false else { return }
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
	}

	/// "Try Free for <period>" for a user who will actually get one; "Subscribe" for everyone else.
	///
	/// Both halves of ``trialEligibility`` are load-bearing and they answer different questions.
	/// ``introOfferEligibility`` is StoreKit's answer about *this Apple Account* — a returning user
	/// who already spent the trial is charged at once, and promising them a free one is the kind of
	/// copy that gets a build rejected. ``Product/hasFreeTrialIntroOffer`` asks whether the product
	/// carries a trial at all, because a product with no introductory offer reports ineligible for
	/// *everyone*, and without this the label would be right by accident rather than by
	/// construction. This function reads the answer they produce together, not the two conditions.
	///
	/// The period comes from the offer, never a literal: the ticket's "Start 14-Day Free Trial"
	/// hardcodes a length that App Store Connect owns and can change without a release.
	private func purchaseButtonTitle(for product: Product) -> String {
		guard trialEligibility == .gettingTrial,
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
		} else if trialEligibility == .gettingTrial,
				  let period = product.subscription?.introductoryOffer?.period.localizedDescription {
			billingNoteText(L10n.Paywall.trialSupport(period))
		} else if trialEligibility == .noTrial, product.hasFreeTrialIntroOffer {
			// The offer's *existence* is checked separately from this customer's eligibility for it.
			// StoreKit answers only the second question, and a product carrying no introductory offer
			// can report `false` for everyone — telling those users they have used up a trial that
			// was never on sale would be a plain untruth. Only the conjunction is safe to state.
			billingNoteText(L10n.Paywall.Billing.immediate)
		}
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

	/// Apple's standard EULA, accepted as the Terms of Use when no custom one is provided.
	// swiftlint:disable:next force_unwrapping
	private static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

	/// The colour this screen's secondary and legal controls are drawn in (AIA-0458).
	///
	/// The app's `AccentColor` is a deliberate neutral grey — `0.700` in light appearance — and
	/// SwiftUI resolves `.tint`, `Link` and `Button` labels to it. On white that is **≈2.1:1**,
	/// against the 4.5:1 WCAG AA wants at these text sizes, so Restore, Manage, Terms of Use and
	/// Privacy Policy were all drawn at roughly half the contrast they need. Dark appearance was
	/// never affected (`0.800` on the sheet background is ≈10.6:1) — this is a light-mode defect.
	///
	/// It matters most on *this* screen: Schedule 2 §3.8(b) requires the Terms and Privacy links to
	/// be accessible within the app, and Guideline 3.1.2 requires disclosure that is "clear and
	/// conspicuous". It was found by reading the uploaded App Review screenshot as evidence rather
	/// than as a picture.
	///
	/// `Color.blue` rather than a new colorset: it is a **system semantic** colour that adapts
	/// across appearances on its own — which is why `PaywallOutlinedAction`'s "this app hardcodes
	/// no colours" does not bar it, and why the app already uses it for interactive elements in
	/// `DrawerContent`, `ConfigurationForm` and `FindingsListView`. Not green, which is this app's
	/// primary-action colour: these controls must stay visually subordinate to Subscribe.
	///
	/// Honest limit: system blue on white is ≈4.0:1 — a ~2× improvement and unambiguously a
	/// control, but still marginally under AA at `.caption2`. Closing that last gap needs a custom
	/// darker blue, i.e. a brand decision. The underline on the two legal links is what makes their
	/// link-ness independent of contrast in the meantime.
	///
	/// Scoped to this screen deliberately. The same grey tints links app-wide; auditing that is a
	/// separate change, and this is the screen App Review reads.
	private static let interactiveTint = Color.blue

}

#if DEBUG
#Preview("Not subscribed") {
	PaywallView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		analytics: nil,
		freeAccessDaysRemaining: { nil }
	)
}

#Preview("Subscribed") {
	let state = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed), isPaymentsEnabled: true)
	return PaywallView(subscriptionState: state, analytics: nil, freeAccessDaysRemaining: { nil })
		.task { await state.start() }
}

/// The hard wall after a window ran out (AIA-0567) — the only presentation that says so.
#Preview("Expired free access") {
	PaywallView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		analytics: nil,
		isRootGate: true,
		statesExpiredFreeAccess: true,
		freeAccessDaysRemaining: { nil }
	)
}

/// The same wall for someone who never had a window — payments on, free access off. Proves the
/// title and the description both stay neutral rather than claiming a loss that never happened.
#Preview("Wall — no window was ever granted") {
	PaywallView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		analytics: nil,
		isRootGate: true,
		freeAccessDaysRemaining: { nil }
	)
}

/// The Settings presentation, mid-window — the only configuration in which a tap on Subscribe has
/// to ask first (AIA-0623).
///
/// **This preview cannot show the confirmation, and that is worth stating rather than discovering.**
/// `MockSubscriptionProvider` exposes no `Product` (a `Product` cannot be constructed outside
/// StoreKit), so `content` renders the "unavailable" branch and there is no Subscribe button to
/// tap. It exists to keep the mid-window input compiling and visible next to the others; the alert
/// itself is reachable only where StoreKit returns a real product — an Xcode run against
/// `Configuration.storekit`, or a TestFlight build.
#Preview("Settings sheet — 9 free days left") {
	PaywallView(
		subscriptionState: SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true),
		analytics: nil,
		freeAccessDaysRemaining: { 9 }
	)
}
#endif
