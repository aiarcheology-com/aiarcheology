//
//  AccountAnalyticsCoordinator.swift
//  AI Archeology
//
//  Cross-device analytics identity + funnel events (AIA-0437).
//

import Combine
import Foundation

/// Joins the auth account to the analytics identity, and emits the two funnel events.
///
/// Deliberately **not** an `ObservableObject` and not a view-layer type: nothing renders from it.
/// It is constructed by the composition root and must be **retained there** — its whole behaviour
/// lives in Combine subscriptions, so a coordinator left as a local would deallocate immediately
/// and stop working with no compile error and no failing test (mirrors `TargetingCoordinator`).
///
/// Constructed only while ``FeatureFlagKey/isCrossDeviceAnalyticsIdentityEnabled`` is on. With the
/// flag off it does not exist, so no identity is ever installed and neither funnel event fires —
/// the app behaves exactly as it did before AIA-0437.
@MainActor
final class AccountAnalyticsCoordinator {
	private let analytics: AnalyticsState
	private let subscriptionState: SubscriptionState
	private var observations: Set<AnyCancellable> = []

	/// The auth context as last delivered, tracked locally because the entitlement observer needs it
	/// and `@Published` values must be read from the sink that delivers them, never re-read.
	///
	/// The *context*, not just the account id: entitlement resolves before auth at launch, so "no
	/// account yet" and "no account, signed out" both look like `nil` at exactly the moment the
	/// entitlement lands. Conflating them would stamp anonymous provenance on every signed-in
	/// subscriber's entitlement, once per launch.
	private var currentContext: EffectiveAuthContext = .indeterminate

	init(
		analytics: AnalyticsState,
		authState: AuthState,
		subscriptionState: SubscriptionState
	) {
		self.analytics = analytics
		self.subscriptionState = subscriptionState

		// The value is taken from the sink, never re-read from `authState`. `@Published` fires on
		// `willSet`, so a sink that re-read the property would observe the value being replaced —
		// i.e. it would install the OUTGOING account (documented in `TargetingCoordinator`).
		//
		// Driven by the context rather than the raw identifier (AIA-0536): the identifier alone
		// cannot distinguish "signed out" from "still resolving", and consent needs to.
		authState.$effectiveContext
			.removeDuplicates()
			.sink { [weak self] context in self?.handleContextChange(context) }
			.store(in: &observations)

		subscriptionState.$isSubscribed
			.removeDuplicates()
			.sink { [weak self] isSubscribed in self?.handleEntitlementChange(isSubscribed: isSubscribed) }
			.store(in: &observations)
	}

	/// Forwards **every** context to analytics, then acts on its own behalf only for those that
	/// correspond to a write of `AuthState.accountIdentifier`.
	///
	/// The two are not the same set, and the difference is load-bearing. `.suspended` is not an
	/// attribution transition — this type must not touch `currentContext` or emit funnel events for
	/// it — but `AnalyticsState` still needs to see it, because it is the only signal distinguishing
	/// "no scope yet, still resolving" from "no scope, and none is coming". Filtering it out here
	/// leaves that branch unreachable in the wired app and strands an offline user on a hold screen
	/// forever, while a test calling `AnalyticsState` directly still passes.
	private func handleContextChange(_ context: EffectiveAuthContext) {
		// Always first, and always unconditional: the identity must be installed before any event is
		// handed over, or the event is attributed to whoever was signed in before (AIA-0437).
		// `AnalyticsState` decides for itself which contexts change attribution — that judgement is
		// not duplicated here (see `EffectiveAuthContext.isAttributionTransition`).
		analytics.updateAuthContext(context)

		guard context.isAttributionTransition else { return }
		currentContext = context

		// `.indeterminate` and `.anonymous` both resolve to no account for *attribution*. They are
		// not interchangeable elsewhere: only `.anonymous` may answer a consent question, and only
		// `.anonymous` stamps anonymous provenance on an entitlement.
		guard context.validatedAccount != nil else {
			// Signing out — or an anonymous user who was already entitled before this fired — still
			// has to reach the entitlement observer, or an anonymous purchase made while signed out
			// would never be marked and would be credited to whoever signs in next.
			handleEntitlementChange(isSubscribed: subscriptionState.isSubscribed)
			return
		}
		// Both funnel events are once-per-account-ever, and `AnalyticsState` owns that bookkeeping:
		// it is the only type that knows how an account maps to its stored marker. Keeping the
		// dedup here in memory would have made `account.signed_in` a launch counter.
		analytics.reportAccountSignedInIfNeeded()

		// Entitlement is resolved before auth at launch (`AppState.initialize` awaits
		// `subscriptionState.start()` before the gates render), so by the time an account arrives
		// the subscription publisher has usually already fired — with no account to attribute it
		// to. Re-check here rather than lose the activation.
		handleEntitlementChange(isSubscribed: subscriptionState.isSubscribed)
	}

	private func handleEntitlementChange(isSubscribed: Bool) {
		guard isSubscribed else {
			// Not entitled. Clear the provenance — but only once auth has actually resolved.
			//
			// The timing is the whole difficulty. `@Published` delivers its *current* value the
			// moment this coordinator subscribes, and at launch that value is `false`, before auth
			// has said anything. Clearing then would wipe a persisted anonymous purchase's
			// provenance on every cold start and hand the credit to whoever signed in next.
			//
			// Gating on "did we previously see `true` in this process" is not enough either: an
			// anonymous entitlement that lapses while the app is *terminated* is never observed
			// going false, so the marker would survive forever and suppress the next legitimate
			// activation. Keying on the context fixes both — by the time a real scope is selected,
			// `isSubscribed == false` genuinely means this device holds no entitlement, whenever it
			// went away.
			switch currentContext {
			case .validated, .anonymous:
				analytics.forgetAnonymousEntitlementProvenance()
			case .indeterminate, .suspended:
				break
			}
			return
		}

		switch currentContext {
		case .validated:
			analytics.reportSubscriptionActivationIfNeeded()
		case .anonymous:
			// Bought without an account — the normal shape under paywall-first. Recorded durably so
			// that whoever signs in later is not credited with someone else's purchase.
			analytics.markEntitlementObservedAnonymously()
		case .indeterminate, .suspended:
			// Auth has not resolved. At launch the entitlement lands *first* (`AppState.initialize`
			// awaits `subscriptionState.start()` before the gates render), so treating "no account
			// yet" as anonymity would mark every signed-in subscriber anonymous on every launch.
			// The account's arrival re-checks the entitlement, which is where this gets decided.
			break
		}
	}
}
