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

	/// Which account may be targeted. The backend's user is targeted only when it matches.
	///
	/// The backend (`identity`) runs ahead of ``AuthState``: before validation it already reports
	/// an incoming account, and after a revocation it may still hold the cached user. So once
	/// AuthState has published an account (or landed `.signedOut`), that verdict decides. Before it
	/// has said anything, the backend's persisted session is the best answer — a relaunch targets
	/// immediately, even offline — but only the first user seen: a different one appearing before
	/// AuthState speaks is a switch nobody validated.
	private enum Vouched: Equatable {
		/// AuthState has not spoken; the first signed-in user the backend reported, if any.
		case backend(firstSeen: String?)
		/// AuthState's published account; `nil` when it vouches for nobody.
		case authState(String?)
	}

	private var vouched: Vouched = .backend(firstSeen: nil)

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
		// The sinks use only the emitted value (see ``Vouched``), never a re-read.
		authGateChanges
			.removeDuplicates()
			.dropFirst()
			.sink { [weak self] gate in
				MainActor.assumeIsolated {
					guard let self else { return }
					if gate == .signedOut { self.vouched = .authState(nil) }
					self.recompute()
				}
			}
			.store(in: &observations)
		accountChanges
			.removeDuplicates()
			.dropFirst()
			.sink { [weak self] account in
				MainActor.assumeIsolated {
					guard let self else { return }
					self.vouched = .authState(account)
					self.recompute()
				}
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

	/// The backend's user if it may be targeted (see ``Vouched``), else `nil`.
	private func targetableUser() -> String? {
		let (userID, isSignedIn) = identity()
		guard isSignedIn, let userID else { return nil }
		switch vouched {
		case .backend(firstSeen: nil):
			vouched = .backend(firstSeen: userID)
			return userID
		case let .backend(firstSeen: firstSeen?):
			return userID == firstSeen ? userID : nil
		case let .authState(account):
			return userID == account ? userID : nil
		}
	}

	private func recompute() {
		if let userID = targetableUser() {
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
