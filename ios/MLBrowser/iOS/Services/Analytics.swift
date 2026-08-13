//
//  Analytics.swift
//  AI Archeology
//
//  Provider-neutral analytics API (AIA-0350).
//

import Combine
import CryptoKit
import Foundation

/// The deliberately small, allow-listed event surface for optional analytics. New events must be
/// added here rather than passing arbitrary names or parameters through from UI code.
enum AnalyticsEvent: Equatable {
	case paywallShown
	case subscribeTapped
	case accountSignedIn
	case subscriptionActivated
	case modelImported(source: ModelAcquisitionSource)
	case detectionSessionSummary(runCountBucket: DetectionRunCountBucket)

	// The app-managed free-access window (AIA-0556, extended by AIA-0567). One funnel: a window
	// opens, its Welcome screen is shown, the user goes exploring, onboarding ends one way or the
	// other, and eventually the window runs out.
	//
	// The grant is once-per-window by construction — it is only ever possible for an install with no
	// anchor. Expiry is not, because it is a fact about the clock rather than an act, and every
	// launch after day 14 re-observes it; ``AnalyticsState/reportFreeAccessWindowExpiredIfNeeded()``
	// is what keeps it a stage count rather than a launch count.
	case freeAccessWindowGranted
	case freeAccessContinueTapped
	case freeAccessWindowExpired

	/// The day-0 Welcome screen went on screen (AIA-0567).
	///
	/// Needed because the split took the day-0 population away from `paywallShown`: that event used
	/// to fire for the day-0 paywall and now cannot, since ``WelcomeView`` is a different screen and
	/// deliberately not a purchase screen. Without this the funnel would lose its second stage
	/// entirely and `paywall.shown` would silently change meaning with no replacement.
	///
	/// Emitted where the once-per-window marker is written, so it cannot outnumber the screen.
	case welcomeShown

	/// Onboarding finished, or the user skipped out of it (AIA-0567).
	///
	/// The tour now sits between the Welcome screen and the consent question, which makes its
	/// drop-off the first-run metric — and until this ticket there was no tour telemetry at all.
	/// Both fire **only for a first run**: Settings → Replay terminates through the same methods,
	/// and counting replays would let this stage outnumber `freeAccessWindowGranted`, which is
	/// once-per-window.
	///
	/// `completed + skipped < continueTapped` by construction — a force-quit mid-tour emits neither.
	/// That gap is abandonment, not event loss.
	case onboardingTourCompleted
	case onboardingTourSkipped

	/// The free-days confirmation was raised — a purchase was about to forfeit an open window
	/// (AIA-0623).
	///
	/// It exists as much for observability of the *screen* as of the user. This confirmation is the
	/// only one in the app that no automated test can drive — the paywall's Subscribe button needs a
	/// real StoreKit `Product`, which the UI-test mock cannot supply — so a dialog that silently
	/// failed to present would leave no trace at all. Against `freeAccessKeepDaysTapped` and
	/// `subscriptionActivated` it does: raises that are never answered are the signature.
	case freeAccessConfirmShown

	/// The user was told a purchase would forfeit the rest of their free window, and kept the days
	/// (AIA-0623).
	///
	/// The only way to tell the two ways a `subscribeTapped` ends without a `subscriptionActivated`
	/// apart: backing out of *our* confirmation, versus cancelling Apple's sheet. That distinction is
	/// the whole cost measurement for this change — a dialog inserted in front of a purchase is a
	/// conversion risk, and without this event nobody could say afterwards whether it was one.
	///
	/// Bounded by `subscribeTapped`, never above it, because it can only follow one. It says nothing
	/// about how many days were at stake: the window's own numbers stay on the device, for the same
	/// reason the grant date does.
	case freeAccessKeepDaysTapped

	var name: String {
		switch self {
		case .paywallShown: "com.aiarcheology.paywall.shown"
		case .subscribeTapped: "com.aiarcheology.subscribe.tapped"
		case .accountSignedIn: "com.aiarcheology.account.signed_in"
		case .subscriptionActivated: "com.aiarcheology.subscription.activated"
		case .modelImported: "com.aiarcheology.model.imported"
		case .detectionSessionSummary: "com.aiarcheology.detection.session_summary"
		case .freeAccessWindowGranted: "com.aiarcheology.free_access.window_granted"
		case .freeAccessContinueTapped: "com.aiarcheology.free_access.continue_tapped"
		case .freeAccessWindowExpired: "com.aiarcheology.free_access.window_expired"
		case .welcomeShown: "com.aiarcheology.welcome.shown"
		case .onboardingTourCompleted: "com.aiarcheology.onboarding.tour_completed"
		case .onboardingTourSkipped: "com.aiarcheology.onboarding.tour_skipped"
		case .freeAccessConfirmShown: "com.aiarcheology.free_access.forfeit_confirm_shown"
		case .freeAccessKeepDaysTapped: "com.aiarcheology.free_access.keep_days_tapped"
		}
	}

	var parameters: [String: String] {
		switch self {
		case .paywallShown, .subscribeTapped, .accountSignedIn, .subscriptionActivated,
			 .freeAccessWindowGranted, .freeAccessContinueTapped, .freeAccessWindowExpired,
			 .welcomeShown, .onboardingTourCompleted, .onboardingTourSkipped,
			 .freeAccessConfirmShown, .freeAccessKeepDaysTapped:
			// Deliberately payload-free. The account is expressed only as the transport's
			// hashed `clientUser`; the raw Clerk id must never travel as a parameter (AIA-0437).
			// The window's own numbers — grant date, days remaining — stay on the device: they
			// are a per-install timestamp, and a funnel needs the stage, not the calendar.
			[:]
		case let .modelImported(source):
			["source": source.rawValue]
		case let .detectionSessionSummary(runCountBucket):
			["run_count_bucket": runCountBucket.rawValue]
		}
	}

	/// Whether this event carries no payload, and is therefore safe to collapse to one occurrence
	/// while buffered pre-consent (AIA-0567).
	///
	/// Every funnel stage answers "did this happen", never "how many times" — two identical
	/// payload-free events are indistinguishable downstream anyway. Events that DO carry a payload
	/// are excluded: `modelImported` and `detectionSessionSummary` are volume measurements whose
	/// counts are the point. See ``AnalyticsState/maxPendingPreConsentEvents``.
	var isCollapsibleWhileBuffered: Bool { parameters.isEmpty }
}

/// The only model-acquisition detail allowed to leave the device. Model name, URL, filename,
/// catalog title, and provider identifier are intentionally excluded.
enum ModelAcquisitionSource: String, Equatable {
	case fileImport = "file_import"
	case catalog = "catalog"
	case directDownload = "direct_download"
}

/// A coarse per-app-session count. Exact run counts are intentionally never transmitted.
enum DetectionRunCountBucket: String, Equatable {
	case oneToFive = "1_5"
	case sixToTwenty = "6_20"
	case twentyOneOrMore = "21_plus"

	static func bucket(for runCount: Int) -> DetectionRunCountBucket? {
		switch runCount {
		case 1...5: .oneToFive
		case 6...20: .sixToTwenty
		case 21...: .twentyOneOrMore
		default: nil
		}
	}
}

/// Provider-neutral analytics boundary. App UI and feature state use this API only; adapters for
/// TelemetryDeck or a future provider belong behind it in the composition root.
@MainActor
protocol AnalyticsTracking: AnyObject {
	func activate()
	func deactivate()
	func track(_ event: AnalyticsEvent)

	/// Set (or clear, with `nil`) the account identity every subsequent signal is attributed to.
	///
	/// The adapter is responsible for hashing: the raw identifier must never leave the device and
	/// must never be logged (AIA-0437). Passing `nil` returns to the transport's own anonymous
	/// installation identity — it does **not** disable analytics.
	func updateAccountIdentity(_ identifier: String?)
}

@MainActor
final class NoOpAnalyticsTracking: AnalyticsTracking {
	func activate() {}
	func deactivate() {}
	func track(_: AnalyticsEvent) {}
	func updateAccountIdentity(_: String?) {}
}

/// Who an analytics consent answer belongs to (AIA-0536).
///
/// **Two buckets, not three.** Device-wide consent — the pre-AIA-0437 model, still in force whenever
/// `isCrossDeviceAnalyticsIdentityEnabled` is off — and anonymous consent are the *same* bucket.
/// Device-wide mode never installs an identity at all, and anonymous mode installs `nil`, which per
/// ``AnalyticsTracking/updateAccountIdentity(_:)`` means the transport's own anonymous installation
/// identity. Identical bytes leave the device and an identical question is put to the user, so
/// storing them separately would only create two ways to answer one question — and a way for each
/// to silently overwrite the other, re-prompting forever.
enum AnalyticsConsentScope: Equatable {
	case anonymous
	case account(String)

	/// The raw account id, or `nil` for the anonymous bucket. This is exactly what the transport is
	/// told, where `nil` means its own anonymous installation identity.
	var accountIdentifier: String? {
		if case let .account(identifier) = self { return identifier }
		return nil
	}
}

/// What the consent gate should do right now (AIA-0536).
///
/// A `Bool` cannot express this. Under the paywall-first gate order nothing blocks on auth, so the
/// app can render before any scope is known — and a two-way branch would then *replace* a live
/// content subtree when the scope resolves, destroying in-flight browser state.
enum AnalyticsConsentPresentation: Equatable {
	/// No scope resolved yet. Hold rather than render something that may have to be torn down.
	case pending
	/// A scope is selected and has not answered.
	case ask
	/// Nothing to ask: this scope has answered, or the remote feature is off.
	case resolved
	/// A session exists but cannot be verified, so no scope can be selected. Distinct from
	/// ``pending`` because it will not resolve on its own — the gate should explain, not spin.
	case unavailable
}

/// Main-actor state combining the remote feature switch with the user's local choice.
///
/// The effective state is `ConfigCat isAnalyticsEnabled && Settings.analyticsEnabled`. The
/// provider is never activated while either part is false.
@MainActor
final class AnalyticsState: ObservableObject {
	private let settings: Settings
	private let tracker: AnalyticsTracking
	private let featureFlags: FeatureFlagsState
	private var detectionRunCount = 0
	/// Events recorded before the user answers the analytics choice (the login/paywall funnel).
	/// Held in memory ONLY — never persisted, never logged — and flushed to the transport iff the
	/// user enables analytics; discarded on decline, remote-flag-off, reset, or app termination.
	/// This defers reporting until consent without anything leaving the device beforehand (AIA-0447).
	private var pendingPreConsentEvents: [AnalyticsEvent] = []
	/// Safety bound so a repeated `onAppear` cannot grow the buffer without limit — not a functional
	/// cap. Payload-free events are collapsed on append; overflow evicts the newest **volume** event.
	///
	/// The old justification no longer holds and is worth stating plainly, because the bound is
	/// unchanged and it would be easy to assume the reasoning is too. It used to read: "the consent
	/// gate takes the screen the moment the deferral lifts, so nothing can accumulate behind it
	/// indefinitely." AIA-0567 broke that. Consent now also waits for the onboarding tour, and a
	/// tour abandoned mid-step — backgrounded, never terminated — leaves the user inside the app,
	/// using it, with the buffer open for as long as they like. `modelImported` and
	/// `detectionSessionSummary` both fire from in there.
	///
	/// Two changes restore a real bound rather than a hopeful one. Collapsing payload-free repeats
	/// caps the funnel stages at one entry each, fewer than ten in total. And overflow evicts the
	/// newest *volume* event rather than either end of the buffer, so no funnel stage can ever be
	/// pushed out — by anything, at any length of session.
	///
	/// Both naive policies fail, in opposite directions, and a test pins each. Drop-oldest evicts
	/// `freeAccessWindowGranted` first, the denominator every later stage is measured against.
	/// Drop-newest never admits anything once full — which bites hardest at a cold hard wall, the
	/// one surface that mounts no `AnalyticsChoiceGate` at all and so leaves `.ask` standing
	/// indefinitely while `paywallShown` and `subscribeTapped` fire. There, drop-newest throws away
	/// the Subscribe tap that converted.
	private static let maxPendingPreConsentEvents = 16
	private var featureFlagObservation: AnyCancellable?

	/// The account that is signed in right now, or `nil` while signed out. Held raw because it is
	/// what the transport hashes; it must never be logged or sent as a parameter (AIA-0437).
	private var currentAccountIdentifier: String?

	/// The consent bucket in force right now, or `nil` while no scope can be selected.
	private var currentScope: AnalyticsConsentScope?

	/// The last scope actually selected, which survives a transition through "no scope". Used to
	/// decide whether an arriving scope is genuinely *different* — see ``applyScope(_:)``.
	private var lastKnownScope: AnalyticsConsentScope?

	/// True while the current `.ask` was raised by **signing out** rather than by arriving or by an
	/// explicit reset (AIA-0536). Sign-out is a disengagement act — surfacing a consent question at
	/// that moment reads as nagging, and consent fails closed, so staying quiet costs nothing. The
	/// gate keeps content up; the question returns at the next arrival, the next sign-in, or an
	/// explicit Restore Defaults.
	@Published private(set) var isAskDeferredAfterSignOut = false

	/// Whether the reason no scope is selected is an unverifiable session rather than one still
	/// resolving. Recorded from `.suspended`, which is otherwise ignored: it changes nothing about
	/// attribution, but a gate that cannot tell "resolving" from "cannot resolve" leaves an offline
	/// user waiting on a spinner that will never finish.
	private var isAuthUnverifiable = false

	/// Mirrors what the tracker has actually been told, so a re-evaluation that changes nothing
	/// stays silent instead of churning the transport.
	private var isTrackerActive = false
	private var trackedIdentity: String?

	/// What the consent gate should render. Replaces the old `shouldShowChoice` Bool (AIA-0536).
	@Published private(set) var consentPresentation: AnalyticsConsentPresentation

	/// Whether analytics is actually sending right now, for the Settings toggle to display.
	///
	/// Derived rather than read from `Settings.analyticsEnabled` directly: that field is only the
	/// *anonymous* bucket's value, so an account-scoped user would see someone else's answer.
	@Published private(set) var isAnalyticsEnabled: Bool
	/// Drives visibility of the Settings control. It changes live with ConfigCat.
	@Published private(set) var isAnalyticsFeatureEnabled: Bool

	/// Whether the account-scoped identity (and with it the account-scoped choice) is switched on.
	///
	/// Captured **once** at construction, deliberately not observed: this decides which consent
	/// model is in force, so honouring a mid-session flip would either start attributing events to
	/// an account that answered a device-wide question, or strand a user mid-consent.
	///
	/// The composition root resolves this through its launch-value mirror (AIA-0513), never from
	/// the live snapshot: the snapshot has not synced at construction, so a direct read captures
	/// the compiled default on every launch and the dashboard never takes effect. A remote change
	/// therefore lands one cold launch after it is first observed.
	private let isAccountIdentityEnabled: Bool

	init(
		settings: Settings,
		tracker: AnalyticsTracking,
		featureFlags: FeatureFlagsState,
		isAccountIdentityEnabled: Bool
	) {
		self.settings = settings
		self.tracker = tracker
		self.featureFlags = featureFlags
		self.isAccountIdentityEnabled = isAccountIdentityEnabled
		isAnalyticsFeatureEnabled = featureFlags.snapshot.isAnalyticsEnabled
		consentPresentation = .pending
		isAnalyticsEnabled = false
		// No account is known at launch — auth resolves later — so nothing activates here. That is
		// deliberate and stronger than it looks: activating before the account is known would emit
		// the transport's automatic session signal anonymously, and it is hashed at enqueue, so no
		// later identity change could repair it (AIA-0437).
		applyRemoteFeatureFlag(featureFlags.snapshot.isAnalyticsEnabled)
		featureFlagObservation = featureFlags.$snapshot
			.dropFirst()
			.sink { [weak self] snapshot in
				self?.applyRemoteFeatureFlag(snapshot.isAnalyticsEnabled)
			}
	}

	/// Select the consent bucket the current auth context permits (AIA-0536).
	///
	/// The context carries the one distinction ``updateAccountIdentity(_:)`` structurally cannot:
	/// "signed out" and "not resolved yet" are both `nil` there, but only the first is a scope that
	/// may be asked for consent and may answer.
	func updateAuthContext(_ context: EffectiveAuthContext) {
		// Device-wide mode is the pre-AIA-0437 contract: no account identity, ever. Structural
		// rather than an accident of the coordinator not being constructed.
		guard isAccountIdentityEnabled else { return }

		guard context.isAttributionTransition else {
			// `.suspended` carries no write of the published identity, so acting on it would
			// deactivate a consented transport on every offline foreground — and the re-activation
			// rebuilds the transport, re-emitting its automatic session signal. Record only that the
			// session is unverifiable, which selects no scope and so can tear nothing down.
			isAuthUnverifiable = true
			applyEffectiveState()
			return
		}

		isAuthUnverifiable = false
		applyScope(Self.scope(for: context))
	}

	/// Point the analytics identity at `identifier`, or clear it with `nil`.
	///
	/// Kept alongside ``updateAuthContext(_:)`` for callers holding a bare account id. A `nil` here
	/// means *no scope* rather than the anonymous bucket — an identifier alone cannot express the
	/// difference, which is the whole reason the context type exists.
	func updateAccountIdentity(_ identifier: String?) {
		guard isAccountIdentityEnabled else { return }
		isAuthUnverifiable = false
		applyScope(identifier.map(AnalyticsConsentScope.account))
	}

	private static func scope(for context: EffectiveAuthContext) -> AnalyticsConsentScope? {
		switch context {
		case .anonymous: .anonymous
		case let .validated(account): .account(account)
		// `.indeterminate` selects nothing — nobody is there to answer. `.suspended` never reaches
		// here; it is filtered as a non-transition before this is called.
		case .indeterminate, .suspended: nil
		}
	}

	private func applyScope(_ scope: AnalyticsConsentScope?) {
		// The buffer and the detection counter both belong to the scope that produced them, and both
		// are discarded when the scope genuinely changes. Sign Out is reachable outside the consent
		// gate, so without this A's buffered funnel would be delivered under B's identity — or under
		// the anonymous bucket — the moment that scope opts in.
		//
		// `if let last` is load-bearing: **the first scope selection of a session is never a
		// boundary.** Written as `lastKnownScope != scope`, `nil != .anonymous` is true and every
		// cold-launch funnel would be discarded before it could ever be delivered. Events recorded
		// before any scope existed cannot belong to another scope, because there was none.
		if let scope, let last = lastKnownScope, last != scope {
			// Spend the OUTGOING scope's detection count before the scope changes.
			// `flushDetectionSessionSummary()` is guarded on the effective state, so it has to run
			// while the outgoing scope is still selected — after the reassignment below it would
			// silently drop. Discarding instead would destroy the summary of exactly the sessions
			// where someone signs in mid-session, which is the normal shape once login is contextual.
			flushDetectionSessionSummary()
			pendingPreConsentEvents.removeAll()
			detectionRunCount = 0
		}

		// The ask-deferral bookkeeping (AIA-0536). Set only on a genuine account→anonymous
		// transition — a sign-out — never on the first selection of a session, so the arrival ask
		// at a cold launch is untouched. Any account arriving clears it: the account question is
		// about the identity just established, and asking then is contextual rather than nagging.
		switch scope {
		case .anonymous where lastKnownScope.map({ if case .account = $0 { true } else { false } }) == true:
			isAskDeferredAfterSignOut = true
		case .account:
			isAskDeferredAfterSignOut = false
		default:
			break
		}

		currentScope = scope
		currentAccountIdentifier = scope?.accountIdentifier
		if let scope { lastKnownScope = scope }

		applyEffectiveState()
	}

	func chooseAnalytics(enabled: Bool) {
		// Nothing to record for nobody: with no scope selected there is no bucket to write into.
		guard isAnalyticsFeatureEnabled, let scope = activeScope else { return }
		// Each branch writes its own bucket end-to-end and touches no key belonging to the other.
		// That separation is the whole safety property — a shared key would let either scope's
		// answer silently overwrite the other's, and a rollback of the cross-device flag would
		// promote one into the other.
		switch scope {
		case .anonymous:
			settings.analyticsChoiceMade = true
		case let .account(identifier):
			settings.analyticsConsentAccountHash = Self.accountHash(identifier)
		}
		// Answered — whatever raised the question, it is no longer deferred.
		isAskDeferredAfterSignOut = false
		setAnalyticsEnabled(enabled)
	}

	func setAnalyticsEnabled(_ enabled: Bool) {
		// Refuses to act for a scope whose consent this device does not hold — otherwise a Settings
		// toggle could enable sending for someone who never answered (AIA-0437).
		guard isAnalyticsFeatureEnabled, let scope = activeScope, consentApplies(to: scope) else { return }
		// Discard the pre-consent buffer on ANY disable. The decline path arrives here from the
		// default off state, so a value-equality shortcut would leave the buffered events sitting
		// there (AIA-0447).
		if !enabled { pendingPreConsentEvents.removeAll() }
		// Deliberately NOT guarded on the stored value being different. The account bucket's flag is
		// shared across accounts, so after A enabled it the value is already `true` when B consents —
		// an equality guard would return early, leave the transport torn down, never install B's
		// identity, and silently drop everything B does while still reporting itself as enabled.
		// Re-deriving is cheap and idempotent: `applyEffectiveState()` makes no tracker calls when
		// nothing actually changed.
		switch scope {
		case .anonymous: settings.analyticsEnabled = enabled
		case .account: settings.analyticsAccountEnabled = enabled
		}
		applyEffectiveState()
	}

	/// Delivers the pre-consent buffer to the transport once analytics is enabled, then clears it.
	/// Clears BEFORE iterating so a re-entrant `track` during delivery cannot double-send (AIA-0447).
	private func flushPendingPreConsentEvents() {
		let pending = pendingPreConsentEvents
		pendingPreConsentEvents.removeAll()
		for event in pending {
			tracker.track(event)
		}
	}

	/// Used by the whole-app reset path. Unlike `setAnalyticsEnabled(false)`, this also tears
	/// down a currently active transport when Settings has already been reset elsewhere.
	func resetAnalyticsChoice() {
		// An explicit reset is the user ASKING to be re-asked — the sign-out deferral must not
		// swallow that (AIA-0536).
		isAskDeferredAfterSignOut = false
		detectionRunCount = 0
		pendingPreConsentEvents.removeAll()
		lastKnownScope = nil
		settings.analyticsEnabled = false
		settings.analyticsChoiceMade = false
		settings.analyticsAccountEnabled = false
		settings.analyticsConsentAccountHash = nil
		// Forced rather than routed through `applyEffectiveState()`: Settings may already have been
		// reset by another path, leaving the cached `isTrackerActive` stale.
		tracker.deactivate()
		isTrackerActive = false
		trackedIdentity = nil
		applyEffectiveState()
	}

	func track(_ event: AnalyticsEvent) {
		guard isAnalyticsFeatureEnabled else { return }
		if isEffectivelyEnabled {
			tracker.track(event)
			return
		}
		// This scope has answered, and said no — drop.
		if let scope = activeScope, consentApplies(to: scope) { return }
		// Consent still an open question for whoever is here (including nobody yet, and nobody at
		// all): record locally, deferred until they decide. Sent only if that scope enables
		// analytics; discarded on decline, and discarded outright if a different scope is selected
		// first (AIA-0447/0437/0536).
		// Collapse repeats of payload-free events rather than stacking them (AIA-0567). This is what
		// keeps the bound unreachable instead of merely survivable: the funnel stages are finitely
		// many and each can now appear at most once, so no amount of re-mounting the paywall or
		// re-tapping Subscribe can push a stage out of the buffer. The cost is that pre-consent
		// *retry counts* are lost — a funnel wants "did they tap Subscribe", not how many times.
		if event.isCollapsibleWhileBuffered, pendingPreConsentEvents.contains(event) { return }
		pendingPreConsentEvents.append(event)
		// On overflow, evict the most recent **volume** event — never a funnel stage, and never the
		// arrival that caused the overflow.
		//
		// Neither of the obvious policies works. Dropping the oldest evicts `freeAccessWindowGranted`
		// first, the denominator every later stage is measured against, which biases conversion
		// upward by shrinking it. Dropping the newest is worse in the case that matters most: once
		// the buffer is full nothing new is ever admitted, so at a cold hard wall — which mounts no
		// consent gate at all, leaving `.ask` standing indefinitely — a `subscribeTapped` arriving
		// after a long session is refused entry. That is the tap that converted.
		//
		// Funnel stages are payload-free and already collapsed on append, so they are bounded by the
		// number of distinct stages, well under the cap. What overflows is volume events, and the
		// honest thing to lose is their tail.
		if pendingPreConsentEvents.count > Self.maxPendingPreConsentEvents {
			if let volumeIndex = pendingPreConsentEvents.lastIndex(where: { $0.isCollapsibleWhileBuffered == false }) {
				pendingPreConsentEvents.remove(at: volumeIndex)
			} else {
				// Unreachable while the number of *distinct* payload-free events stays under the cap
				// — they collapse on append, so they cannot exceed their own count, which is well
				// below 16. Written out anyway because the guarantee above is a claim about the
				// funnel, and the obvious fallback quietly breaks it: removing from the front takes
				// `freeAccessWindowGranted`, the denominator. Dropping the newest loses a late stage
				// instead, which is the cheaper end to lose.
				assertionFailure("Pre-consent buffer overflowed with no volume event — the funnel stages have outgrown the cap.")
				pendingPreConsentEvents.removeLast()
			}
		}
	}

	func recordDetectionRun() {
		guard isEffectivelyEnabled else { return }
		detectionRunCount += 1
	}

	/// Emits at most one coarse detection summary per **scope stint** — one uninterrupted run of a
	/// single consent scope being selected — not per app session (AIA-0536).
	///
	/// A scope change spends the outgoing scope's count on the way out (see ``applyScope(_:)``), so
	/// A → B → A within one session emits two summaries for A. Both carry only A's own runs and each
	/// is attributed to A, so nothing is misreported; the cardinality is what changed. Anything
	/// aggregating these must not assume one per user per session.
	func flushDetectionSessionSummary() {
		guard isEffectivelyEnabled,
			let bucket = DetectionRunCountBucket.bucket(for: detectionRunCount) else { return }
		tracker.track(.detectionSessionSummary(runCountBucket: bucket))
		detectionRunCount = 0
	}

	// MARK: - Effective state

	/// The scope whose answer applies right now.
	///
	/// With the cross-device identity **off** there is no scope machinery at all — the coordinator
	/// that delivers contexts is not even constructed — so the anonymous bucket applies
	/// unconditionally and `currentScope` is never consulted. Consulting it there would leave every
	/// flag-off build with no scope, hence no prompt and no analytics: a total silent loss on
	/// precisely the path taken when something else has already gone wrong.
	private var activeScope: AnalyticsConsentScope? {
		isAccountIdentityEnabled ? currentScope : .anonymous
	}

	/// True when this device holds `scope`'s own answer. Fails closed for a scope we hold none for.
	private func consentApplies(to scope: AnalyticsConsentScope) -> Bool {
		switch scope {
		case .anonymous:
			// No `analyticsConsentAccountHash == nil` conjunct any more. That guard existed because
			// one stored on/off flag had to serve both consent models; now the account bucket owns
			// `analyticsAccountEnabled` and never writes these keys, so an account's answer cannot
			// be mistaken for an anonymous one — nor promoted into one by a flag rollback.
			return settings.analyticsChoiceMade
		case let .account(identifier):
			return settings.analyticsConsentAccountHash == Self.accountHash(identifier)
		}
	}

	/// The single predicate for "may anything be sent at all".
	private var isEffectivelyEnabled: Bool {
		guard isAnalyticsFeatureEnabled,
			let scope = activeScope,
			consentApplies(to: scope) else { return false }
		switch scope {
		case .anonymous: return settings.analyticsEnabled
		case .account: return settings.analyticsAccountEnabled
		}
	}

	private var derivedConsentPresentation: AnalyticsConsentPresentation {
		guard isAnalyticsFeatureEnabled else { return .resolved }
		guard let scope = activeScope else {
			return isAuthUnverifiable ? .unavailable : .pending
		}
		return consentApplies(to: scope) ? .resolved : .ask
	}

	/// Re-derives everything that depends on remote flag × account × stored choice, and moves the
	/// transport to match. Every path that can change one of those three ends here, which is what
	/// keeps the identity attached across re-activations: `activate()` rebuilds the transport's
	/// configuration and drops any identity it held, so a remote flag flip or a reset-then-re-enable
	/// would otherwise resume sending anonymously (AIA-0437).
	private func applyEffectiveState() {
		// Both derived values are computed BEFORE the switch, because `case (true, true)` returns
		// early when the identity is unchanged and anything below it is therefore conditional on a
		// transport detail that has nothing to do with either value.
		//
		// Structural, not a fix for a live defect: no reachable transition currently both takes that
		// early return and changes these — reaching it requires delivery to stay enabled under an
		// unchanged identity, which pins both values to what they already were. Mutation-testing the
		// order confirms that (moving these below the switch fails no test). The order is kept
		// anyway, because "correct only as long as nobody adds a case" is not worth the two lines.
		consentPresentation = derivedConsentPresentation
		isAnalyticsEnabled = isEffectivelyEnabled

		switch (isTrackerActive, isEffectivelyEnabled) {
		case (false, true):
			// Identity BEFORE activation, not after. Activation is what initialises the transport,
			// and the transport emits its automatic session signal from initialisation using
			// whatever identity it holds at that moment. Activating first would attribute that
			// signal to the previously retained account — the adapter keeps the last identity so a
			// re-enable is re-attributed — and the signal is hashed at enqueue, so the correction
			// arriving a line later could never repair it (AIA-0437).
			//
			// Device-wide mode never touches the identity API at all — not even with `nil`. The
			// contract worth pinning is "no identity traffic under device-wide consent", which is
			// cheaper to verify than "only harmless identity traffic".
			if isAccountIdentityEnabled {
				tracker.updateAccountIdentity(currentAccountIdentifier)
			}
			tracker.activate()
			trackedIdentity = currentAccountIdentifier
			isTrackerActive = true
			// The single activation edge, and therefore the only place a buffer flush cannot be
			// missed. Previously only `setAnalyticsEnabled` flushed, which stranded events whenever
			// delivery was enabled by an *arriving scope that had already consented* rather than by
			// an answer — reachable today, and routine once sign-in is mid-session.
			flushPendingPreConsentEvents()
		case (true, true):
			guard trackedIdentity != currentAccountIdentifier else { return }
			tracker.updateAccountIdentity(currentAccountIdentifier)
			trackedIdentity = currentAccountIdentifier
		case (true, false):
			// Covers sign-out, an account whose consent we lack, a decline, and the remote kill
			// switch. `deactivate()` clears the transport identity as well as stopping delivery.
			tracker.deactivate()
			trackedIdentity = nil
			isTrackerActive = false
		case (false, false):
			break
		}
	}

	/// Reports a funnel event at most once for the signed-in account, ever.
	///
	/// The marker is the account's own hash rather than a `Bool`. A shared flag is wrong in both
	/// directions once a second account is involved: A's flag would suppress B's first report, and
	/// clearing it for B would un-suppress a report A had already made. Keying it to the account
	/// removes the need to reset anything when the consent slot changes.
	///
	/// Deliberately marked at *emit* time, not at delivery: an event emitted before consent is
	/// buffered and may never be delivered (a decline discards it). Re-reporting it later would
	/// count one conversion twice, which is the worse error for a funnel.
	private func reportOncePerAccount(_ event: AnalyticsEvent, markedBy storedHash: ReferenceWritableKeyPath<Settings, String?>) {
		guard isAnalyticsFeatureEnabled, let identifier = currentAccountIdentifier else { return }
		let hash = Self.accountHash(identifier)
		guard settings[keyPath: storedHash] != hash else { return }
		settings[keyPath: storedHash] = hash
		track(event)
	}

	/// `account.signed_in` — the funnel's sign-in stage. Once per account, never once per launch.
	func reportAccountSignedInIfNeeded() {
		reportOncePerAccount(.accountSignedIn, markedBy: \.analyticsSignedInReportedAccountHash)
	}

	/// `subscription.activated` — conversion *timing* for this account. See ANALYTICS.md for why it
	/// is not a conversion rate under the current gate order.
	///
	/// Refuses to fire for an entitlement whose provenance is anonymous (AIA-0536). Under
	/// paywall-first, buying happens before signing in — often instead of it — so "an account holds
	/// an entitlement" no longer implies that account bought it. Attributing it to whoever signs in
	/// next would invent a conversion, and the funnel would over-count every anonymous purchase
	/// followed by a sign-in. The honest report is nothing; a real association needs a backend that
	/// can prove ownership.
	func reportSubscriptionActivationIfNeeded() {
		guard settings.subscriptionObservedAnonymously == false else { return }
		reportOncePerAccount(.subscriptionActivated, markedBy: \.analyticsActivationReportedAccountHash)
	}

	/// `free_access.window_expired` — the free window ran out. Reported once per device, ever.
	///
	/// The marker is what makes this a funnel stage instead of a launch counter. Expiry is not an
	/// act the user performs; it is a fact the app re-observes on **every** launch after day 14, so
	/// an unguarded report would out-number `window_granted` by however often that user opens the
	/// app — and the ratio between those two is the only thing the stage is good for.
	///
	/// Marked at *emit*, not at delivery, for the same reason ``reportOncePerAccount(_:markedBy:)``
	/// is: an event emitted before consent is buffered and may never be delivered, and re-reporting
	/// it later would count one expiry twice. Deliberately **not** account-scoped either — the
	/// window belongs to the install, and nobody need be signed in for it to run out.
	///
	/// Reports nothing about the purchase that may follow. A subscription bought at this wall
	/// carries whatever provenance the entitlement observer gives it, and with nobody signed in
	/// that is anonymous and stays anonymous (AIA-0536) — a free period ending is not evidence of
	/// who owns what came next.
	func reportFreeAccessWindowExpiredIfNeeded() {
		guard isAnalyticsFeatureEnabled, settings.analyticsFreeAccessExpiryReported == false else { return }
		settings.analyticsFreeAccessExpiryReported = true
		track(.freeAccessWindowExpired)
	}

	/// Record that the current entitlement was first seen with nobody signed in.
	func markEntitlementObservedAnonymously() {
		settings.subscriptionObservedAnonymously = true
	}

	/// Forget the anonymous provenance once the entitlement itself is gone: the next one is a fresh
	/// purchase, and its provenance is decided when it arrives rather than inherited.
	func forgetAnonymousEntitlementProvenance() {
		settings.subscriptionObservedAnonymously = false
	}

	/// SHA-256 of the account id, so the device never persists a raw account identifier.
	private static func accountHash(_ identifier: String) -> String {
		SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	private func applyRemoteFeatureFlag(_ isEnabled: Bool) {
		isAnalyticsFeatureEnabled = isEnabled
		if isEnabled == false {
			detectionRunCount = 0
			pendingPreConsentEvents.removeAll()
		}
		applyEffectiveState()
	}

	#if DEBUG
	/// Test-only: number of events currently buffered pre-consent. Not part of the production API.
	var pendingPreConsentCount: Int { pendingPreConsentEvents.count }
	#endif
}
