//
//  TargetingCoordinator.swift
//  AI Archeology
//
//  Keeps the ConfigCat evaluation user in sync with the signed-in identity (AIA-0115).
//

import Combine
import Foundation

/// Recomputes the ConfigCat targeting user on every auth-gate transition, every change of the
/// published account, *and* every subscription-entitlement change (they move independently), then
/// forces the two updates the SDK does not deliver by itself:
///
/// 1. `FeatureFlagsState.refresh()` — `setDefaultUser` fires no change hook, and the state
///    republishes only on an actual value change, so targeted config is re-fetched explicitly.
/// 2. `MessageCenterState.reevaluate()` — identity gates visibility directly (interactive
///    requires sign-in) even when the config payload is byte-identical, so the pipeline must
///    re-run regardless of whether a republish happens.
///
/// The last-set context is persisted so a background refresh (Phase A notifications) can
/// restore targeting without a signed-in UI session; sign-out clears it (fail closed: no
/// persisted context ⇒ background syncs evaluate untargeted defaults only).
///
/// The account is observed separately from the gate (AIA-0522): ``AuthState`` suppresses equal
/// gate values, so an in-place account switch (A signs out and B signs in without the gate leaving
/// `.ready`) publishes nothing on the gate and would leave targeting on A. The same reason
/// ``AuthState/accountIdentifier`` exists for analytics (AIA-0437).
///
/// `@Published` emits on `willSet`, so the sinks below must never re-read ``AuthState``: `identity`
/// reads the auth backend directly, which already holds the incoming value.
///
/// Deliberately not an `ObservableObject` — nothing renders from it; it is container-owned
/// plumbing, like ``MessageReplyCoordinator``.
@MainActor
final class TargetingCoordinator {

	/// Persisted under this key as JSON: `{"id": …, "custom": {…}}`. Read by the S7 background
	/// sync; device-local only.
	static let contextDefaultsKey = "appMessages.targetingContext"

	struct Context: Codable, Equatable {
		let id: String
		let custom: [String: String]
	}

	private let identity: @MainActor () -> (userID: String?, isSignedIn: Bool)
	private let isSubscribed: @MainActor () -> Bool
	private let provider: FeatureFlagProviding
	private let featureFlags: FeatureFlagsState
	private let messageCenter: MessageCenterState
	private let defaults: UserDefaults
	private let appVersion: String
	private let localeIdentifier: String

	private var observations: Set<AnyCancellable> = []
	private var refreshTask: Task<Void, Never>?

	init(
		identity: @escaping @MainActor () -> (userID: String?, isSignedIn: Bool),
		isSubscribed: @escaping @MainActor () -> Bool,
		authGateChanges: AnyPublisher<AuthGate, Never>,
		accountChanges: AnyPublisher<String?, Never>,
		subscriptionChanges: AnyPublisher<Bool, Never>,
		provider: FeatureFlagProviding,
		featureFlags: FeatureFlagsState,
		messageCenter: MessageCenterState,
		defaults: UserDefaults = .standard,
		appVersion: String = AppEnvironment.shortVersion ?? "0",
		localeIdentifier: String = Locale.current.identifier
	) {
		self.identity = identity
		self.isSubscribed = isSubscribed
		self.provider = provider
		self.featureFlags = featureFlags
		self.messageCenter = messageCenter
		self.defaults = defaults
		self.appVersion = appVersion
		self.localeIdentifier = localeIdentifier

		// All three publishers are `@Published` projections, which emit on willSet from the main
		// actor; `assumeIsolated` mirrors MessageCenterState's foreground observer (AGENTS §4).
		// `.signedOut` is AuthState's verdict, and it can land while the backend still holds a
		// revoked user it has not dropped yet — so it clears, rather than asking the backend.
		authGateChanges
			.removeDuplicates()
			.dropFirst()
			.sink { [weak self] gate in
				MainActor.assumeIsolated { self?.recompute(clearingAccount: gate == .signedOut) }
			}
			.store(in: &observations)
		// The account published is the one to target, so a `nil` clears targeting without asking the
		// backend. `AuthState` writes `nil` before it validates an incoming account: asking would
		// target that account unvalidated, and ignoring the write would leave the outgoing one
		// targeted for as long as validation cannot finish (offline, or no usable identifier).
		accountChanges
			.removeDuplicates()
			.dropFirst()
			.sink { [weak self] account in
				MainActor.assumeIsolated { self?.recompute(clearingAccount: account == nil) }
			}
			.store(in: &observations)
		subscriptionChanges
			.removeDuplicates()
			.dropFirst()
			.sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
			.store(in: &observations)

		// Seed once: a relaunch with a live session must target immediately, not wait for the
		// first transition.
		recompute()
	}

	/// - Parameter clearingAccount: targets nobody, whatever the backend reports — for the moments
	///   ``AuthState`` stops publishing an account or concludes nobody is signed in.
	private func recompute(clearingAccount: Bool = false) {
		let (userID, isSignedIn) = clearingAccount ? (nil, false) : identity()
		if isSignedIn, let userID {
			let context = Context(id: userID, custom: [
				"appVersion": appVersion,
				"platform": "iOS",
				"locale": localeIdentifier,
				"subscribed": isSubscribed() ? "true" : "false"
			])
			provider.setUser(id: context.id, custom: context.custom)
			if let data = try? JSONEncoder().encode(context) {
				defaults.set(data, forKey: Self.contextDefaultsKey)
			}
			// The Clerk id stays out of the log line; presence + attributes tell the whole story.
			LoggingPolicy.debug(
				"App messages: targeting user set (subscribed=\(context.custom["subscribed"] ?? "?"))",
				logger: .state
			)
		} else {
			provider.clearUser()
			defaults.removeObject(forKey: Self.contextDefaultsKey)
			LoggingPolicy.debug("App messages: targeting cleared (no account)", logger: .state)
		}

		// Identity gates visibility synchronously (interactive ⇢ signed-in), independent of
		// whether the targeted config differs — never wait on the network for that.
		messageCenter.reevaluate()

		// Then fetch config under the new user. Coalesce: a transition landing mid-refresh
		// supersedes the in-flight fetch rather than racing it.
		refreshTask?.cancel()
		refreshTask = Task { [featureFlags] in
			await featureFlags.refresh()
		}
	}
}
