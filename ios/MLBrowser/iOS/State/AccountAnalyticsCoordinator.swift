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

	/// The account currently signed in, tracked locally because the entitlement observer needs it
	/// and `@Published` values must be read from the sink that delivers them, never re-read.
	private var currentAccount: String?

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
	/// attribution transition — this type must not touch `currentAccount` or emit funnel events for
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
		// `.indeterminate` and `.anonymous` both resolve to no account today. They stop being
		// interchangeable once consent is scope-aware: only `.anonymous` may be asked and answer.
		let identifier = context.validatedAccount
		currentAccount = identifier

		guard identifier != nil else { return }
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
		// Attributable only with an account: an activation with no identity would land on the
		// anonymous device identity and could never be joined to the account that paid.
		guard isSubscribed, currentAccount != nil else { return }
		analytics.reportSubscriptionActivationIfNeeded()
	}
}
