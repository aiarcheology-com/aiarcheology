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

	var name: String {
		switch self {
		case .paywallShown: "com.aiarcheology.paywall.shown"
		case .subscribeTapped: "com.aiarcheology.subscribe.tapped"
		case .accountSignedIn: "com.aiarcheology.account.signed_in"
		case .subscriptionActivated: "com.aiarcheology.subscription.activated"
		case .modelImported: "com.aiarcheology.model.imported"
		case .detectionSessionSummary: "com.aiarcheology.detection.session_summary"
		}
	}

	var parameters: [String: String] {
		switch self {
		case .paywallShown, .subscribeTapped, .accountSignedIn, .subscriptionActivated:
			// Deliberately payload-free. The account is expressed only as the transport's
			// hashed `clientUser`; the raw Clerk id must never travel as a parameter (AIA-0437).
			[:]
		case let .modelImported(source):
			["source": source.rawValue]
		case let .detectionSessionSummary(runCountBucket):
			["run_count_bucket": runCountBucket.rawValue]
		}
	}
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
	/// cap (the pre-consent surface is two payload-free events). Drop-oldest on overflow.
	private static let maxPendingPreConsentEvents = 16
	private var featureFlagObservation: AnyCancellable?

	/// The account that is signed in right now, or `nil` while signed out. Held raw because it is
	/// what the transport hashes; it must never be logged or sent as a parameter (AIA-0437).
	private var currentAccountIdentifier: String?

	/// The last non-`nil` account seen, which survives a sign-out. Used to decide whether an
	/// arriving account is genuinely *different* — see ``updateAccountIdentity(_:)``.
	private var lastKnownAccountIdentifier: String?

	/// Mirrors what the tracker has actually been told, so a re-evaluation that changes nothing
	/// stays silent instead of churning the transport.
	private var isTrackerActive = false
	private var trackedIdentity: String?

	/// True only while the remote feature is enabled and the signed-in account has not chosen.
	@Published private(set) var shouldShowChoice: Bool
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
		shouldShowChoice = false
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

	/// Point the analytics identity at `identifier`, or clear it with `nil` on sign-out.
	///
	/// Consent is per account, so this is also what decides whether analytics may run at all: an
	/// account whose choice we do not hold fails closed and is asked.
	/// Point analytics at whatever the current auth context permits (AIA-0536).
	///
	/// The context carries one distinction ``updateAccountIdentity(_:)`` structurally cannot: it
	/// separates "signed out" from "not resolved yet", which are both `nil` there. Both still map to
	/// the same call today, so routing the coordinator through here changes no behaviour — the
	/// distinction becomes load-bearing when consent itself becomes scope-aware.
	func updateAuthContext(_ context: EffectiveAuthContext) {
		// Not every context is something to react to. `.suspended` carries no write of the published
		// identity, so acting on it would deactivate a consented transport on every offline
		// foreground — and the re-activation rebuilds the transport, re-emitting its automatic
		// session signal and inflating user counts for someone who never went anywhere.
		guard context.isAttributionTransition else { return }
		updateAccountIdentity(context.attributedAccount)
	}

	func updateAccountIdentity(_ identifier: String?) {
		// Device-wide mode is the pre-AIA-0437 contract: no account identity, ever. The guard makes
		// that structural rather than an accident of the coordinator not being constructed — the two
		// are resolved from one value in the composition root, but no future caller may be able to
		// install an identity under a consent model that never asked the user about one.
		guard isAccountIdentityEnabled else { return }
		currentAccountIdentifier = identifier

		if let identifier {
			// Discard the pre-consent buffer when a genuinely DIFFERENT account arrives. Sign Out
			// is reachable from the root paywall — outside the consent gate — so without this, A's
			// buffered funnel would be delivered under B's identity the moment B opts in. Compared
			// against the last non-`nil` account, not the immediately previous value, so that
			// signing out and back in as the same person keeps their own events.
			if let last = lastKnownAccountIdentifier, last != identifier {
				pendingPreConsentEvents.removeAll()
				// The detection counter is account-scoped for exactly the same reason as the buffer,
				// and is easy to miss because it is not an event yet. It accumulates while A is
				// consented and is only spent at backgrounding, so carrying it across an account
				// change would report A's activity in a summary attributed to B (AIA-0437).
				detectionRunCount = 0
			}
			lastKnownAccountIdentifier = identifier
		}

		applyEffectiveState()
	}

	func chooseAnalytics(enabled: Bool) {
		guard isAnalyticsFeatureEnabled else { return }
		if isAccountIdentityEnabled {
			// The choice is recorded against the account that gave it, so only a signed-in account
			// can answer. Nothing to record for nobody.
			guard let identifier = currentAccountIdentifier else { return }
			settings.analyticsConsentAccountHash = Self.accountHash(identifier)
		} else {
			// Device-wide mode records a device-wide choice. Clearing any account-scoped hash is
			// what stops the rollback path above from looping: with a hash still present the
			// predicate would keep failing closed and the prompt would never go away.
			settings.analyticsConsentAccountHash = nil
		}
		settings.analyticsChoiceMade = true
		shouldShowChoice = false
		setAnalyticsEnabled(enabled)
	}

	func setAnalyticsEnabled(_ enabled: Bool) {
		// Refuses to act for an account whose consent this device does not hold — otherwise a
		// Settings toggle could enable sending for someone who never answered (AIA-0437).
		guard isAnalyticsFeatureEnabled, consentAppliesToCurrentAccount else { return }
		// Discard the pre-consent buffer on ANY disable. The decline path arrives here from the
		// default `analyticsEnabled == false` state, so a value-equality shortcut would leave the
		// buffered events sitting there (AIA-0447).
		if !enabled { pendingPreConsentEvents.removeAll() }
		// Deliberately NOT guarded on `settings.analyticsEnabled != enabled`. The stored flag is
		// device-wide while consent is per account, so after A enabled it the value is already
		// `true` when B consents — an equality guard would return early, leave the transport torn
		// down, never install B's identity, and silently drop everything B does while still
		// reporting itself as enabled. Re-deriving is cheap and idempotent: `applyEffectiveState()`
		// makes no tracker calls when nothing actually changed.
		settings.analyticsEnabled = enabled
		applyEffectiveState()
		// Safe to call unconditionally — a no-op once the buffer is empty, which is what keeps a
		// repeated enable from re-delivering anything.
		if isEffectivelyEnabled { flushPendingPreConsentEvents() }
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
		detectionRunCount = 0
		pendingPreConsentEvents.removeAll()
		settings.analyticsEnabled = false
		settings.analyticsChoiceMade = false
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
		// This account has answered, and said no — drop.
		guard consentAppliesToCurrentAccount == false else { return }
		// Consent still an open question for whoever is signed in (including nobody yet): record
		// locally, deferred until they decide. Sent only if they enable analytics; discarded on
		// decline, and discarded outright if a different account arrives first (AIA-0447/0437).
		pendingPreConsentEvents.append(event)
		let overflow = pendingPreConsentEvents.count - Self.maxPendingPreConsentEvents
		if overflow > 0 { pendingPreConsentEvents.removeFirst(overflow) }
	}

	func recordDetectionRun() {
		guard isEffectivelyEnabled else { return }
		detectionRunCount += 1
	}

	/// Emits at most one coarse detection summary per app session.
	func flushDetectionSessionSummary() {
		guard isEffectivelyEnabled,
			let bucket = DetectionRunCountBucket.bucket(for: detectionRunCount) else { return }
		tracker.track(.detectionSessionSummary(runCountBucket: bucket))
		detectionRunCount = 0
	}

	// MARK: - Effective state

	/// True when the stored choice belongs to the account signed in right now. Fails closed: no
	/// account, or an account we hold no choice for, is never "consented".
	private var consentAppliesToCurrentAccount: Bool {
		// Feature off: the pre-AIA-0437 contract. No account identity is ever sent, so a device-wide
		// choice for device-scoped analytics is coherent and nobody is re-prompted.
		//
		// The stored hash is checked even here. A choice recorded against a specific account is NOT
		// a device-wide choice, so if the feature is ever rolled back, letting any account inherit
		// it would hand A's consent to B — the exact failure the account scoping exists to prevent.
		// Fail closed and ask again instead.
		guard isAccountIdentityEnabled else {
			return settings.analyticsConsentAccountHash == nil && settings.analyticsChoiceMade
		}
		guard let identifier = currentAccountIdentifier,
			let storedHash = settings.analyticsConsentAccountHash else { return false }
		return storedHash == Self.accountHash(identifier)
	}

	/// The single predicate for "may anything be sent at all".
	private var isEffectivelyEnabled: Bool {
		isAnalyticsFeatureEnabled && consentAppliesToCurrentAccount && settings.analyticsEnabled
	}

	/// Re-derives everything that depends on remote flag × account × stored choice, and moves the
	/// transport to match. Every path that can change one of those three ends here, which is what
	/// keeps the identity attached across re-activations: `activate()` rebuilds the transport's
	/// configuration and drops any identity it held, so a remote flag flip or a reset-then-re-enable
	/// would otherwise resume sending anonymously (AIA-0437).
	private func applyEffectiveState() {
		shouldShowChoice = isAnalyticsFeatureEnabled
			&& consentAppliesToCurrentAccount == false
			// With the feature on, only a signed-in account can be asked — the question is "may we
			// attribute *you* across devices", which is meaningless without an account. With it off
			// there is no account requirement, matching the pre-AIA-0437 prompt.
			&& (isAccountIdentityEnabled == false || currentAccountIdentifier != nil)

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
	func reportSubscriptionActivationIfNeeded() {
		reportOncePerAccount(.subscriptionActivated, markedBy: \.analyticsActivationReportedAccountHash)
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
