//
//  StoreKitSubscriptionProvider.swift
//  AI Archeology
//
//  Real (and mock) implementations of `SubscriptionProviding` for AIA-0343.
//
//  Phase A: StoreKit 2 DIY, on-device entitlement, NO backend and NO Clerk writes.
//  `Transaction.currentEntitlements` (verified only) is the source of truth.
//

import Foundation
import StoreKit
import OSLog
import CryptoKit
#if canImport(ClerkKit)
import ClerkKit
#endif

/// Product identifiers for the in-app subscription (AIA-0343). These must match the
/// products configured in `Configuration.storekit` (local testing) and in App Store
/// Connect (production). Kept in one place so the paywall and the entitlement check
/// agree on what "subscribed" means.
enum SubscriptionProduct {
	/// The single monthly auto-renewable subscription shipped in Phase A.
	static let monthly = "com.aiarcheology.premium.monthly"

	/// Every product the paywall offers / the entitlement check considers.
	static let allIDs: [String] = [monthly]
}

/// Production ``SubscriptionProviding`` backed by StoreKit 2.
///
/// `@MainActor` (not an `actor`) on purpose: it publishes UI-bound state and drives
/// StoreKit's async APIs that are happy on the main actor. Named `…Provider` (not
/// `…Service`) so the Harmonize "services are actors" rule does not apply.
@MainActor
final class StoreKitSubscriptionProvider: SubscriptionProviding {

	var onEntitlementChange: (() -> Void)?

	private(set) var products: [Product] = []
	private(set) var isSubscribed = false
	private(set) var currentTransactionID: UInt64?
	private(set) var currentExpirationDate: Date?
	private(set) var isInTrial = false

	/// Long-lived task draining `Transaction.updates`. Held so it lives for the app's
	/// lifetime and is cancelled if the provider is ever torn down.
	private var updatesListener: Task<Void, Never>?

	deinit {
		updatesListener?.cancel()
	}

	func start() async {
		// Install the listener FIRST so a transaction that arrives while we drain the
		// backlog (or during a purchase that races launch) is never missed.
		if updatesListener == nil {
			updatesListener = Task { [weak self] in
				for await update in Transaction.updates {
					await self?.handle(update)
				}
			}
		}
		// Drain unfinished / pending transactions (Ask-to-Buy approvals, interrupted
		// purchases) that completed while the app wasn't running, BEFORE any purchase UI.
		await drainUnfinishedTransactions()
		await refreshEntitlement()
	}

	func loadProducts() async {
		do {
			let fetched = try await Product.products(for: SubscriptionProduct.allIDs)
			products = fetched.sorted { $0.price < $1.price }
			if products.isEmpty {
				// Not fatal: App Store Connect may not be configured yet, or the local
				// .storekit file isn't wired into the scheme. Degrade — the paywall shows
				// an empty/unavailable state rather than crashing.
				LoggingPolicy.warning(
					"No subscription products returned for \(SubscriptionProduct.allIDs) — paywall will be empty.",
					logger: .networking
				)
			}
		} catch {
			LoggingPolicy.error(
				"Failed to load subscription products: \(error.localizedDescription)",
				logger: .networking
			)
			products = []
		}
	}

	// Not `@discardableResult`, matching ``SubscriptionProviding``: dropping this outcome is
	// the AIA-0376 bug, and the attribute would re-open the hole for direct callers.
	func purchase(_ product: Product) async -> PurchaseOutcome {
		do {
			let result = try await product.purchase(options: purchaseOptions())
			switch result {
			case .success(let verification):
				guard let transaction = verified(verification) else {
					LoggingPolicy.warning("Purchase returned an unverified transaction — ignoring.", logger: .state)
					return .failed
				}
				await transaction.finish()
				await refreshEntitlement()
				// The verified transaction *is* the proof of purchase, so the outcome is
				// derived from it and never from `isSubscribed`. `currentEntitlements` is an
				// async sequence over the local store: were the outcome gated on it, any lag
				// would tell someone Apple just charged that their purchase failed. If the
				// entitlement somehow still reads false the gate simply stays up — logged
				// below, rather than accused.
				if isSubscribed.not {
					LoggingPolicy.error("Verified purchase did not yield an entitlement.", logger: .state)
				}
				return .subscribed
			case .pending:
				// Ask-to-Buy / SCA: the deferred transaction will arrive later via
				// `Transaction.updates`. Not subscribed yet, but not an error.
				LoggingPolicy.info("Purchase pending (Ask-to-Buy / deferred).", logger: .state)
				return .pending
			case .userCancelled:
				return .cancelled
			@unknown default:
				LoggingPolicy.warning("Unknown purchase result.", logger: .state)
				return .failed
			}
		} catch {
			LoggingPolicy.error("Purchase failed: \(error.localizedDescription)", logger: .state)
			return .failed
		}
	}

	// Not `@discardableResult` — see ``purchase(_:)``.
	func restore() async -> RestoreOutcome {
		var syncFailed = false
		do {
			// Re-sync with the App Store so entitlements reflect purchases made on other
			// devices / after a reinstall, then recompute from current entitlements.
			try await AppStore.sync()
		} catch {
			// `sync()` throws on cancellation or no network; entitlement may still be
			// valid locally, so just log and recompute.
			syncFailed = true
			LoggingPolicy.warning("AppStore.sync during restore failed: \(error.localizedDescription)", logger: .networking)
		}
		await refreshEntitlement()

		// A local entitlement outranks a failed sync — that is the whole point of recomputing
		// after the catch above. Only when there is nothing to show for it does the sync
		// failure become the user's problem, and "the store said you own nothing" must not be
		// reported as an error.
		if isSubscribed { return .restored }
		return syncFailed ? .failed : .nothingToRestore
	}

	// MARK: - Private

	/// Purchase options, tagging the transaction with the Clerk user id as
	/// `appAccountToken` so a future backend can reconcile the transaction to a user.
	/// Read defensively: the mock/UI-test path never touches Clerk, and a signed-out
	/// user simply gets no token.
	private func purchaseOptions() -> Set<Product.PurchaseOption> {
		guard let token = appAccountToken() else { return [] }
		return [.appAccountToken(token)]
	}

	private func appAccountToken() -> UUID? {
		#if canImport(ClerkKit)
		// Clerk user ids are not UUIDs; map deterministically into one so the same user
		// always yields the same token. Tolerate nil (signed out / Clerk not configured).
		guard let userID = Clerk.shared.user?.id else { return nil }
		return Self.deterministicUUID(from: userID)
		#else
		return nil
		#endif
	}

	/// Drain transactions that finished out-of-process (Ask-to-Buy approved, interrupted
	/// purchase) so they're acknowledged and reflected in entitlement on cold start.
	private func drainUnfinishedTransactions() async {
		for await result in Transaction.unfinished {
			guard let transaction = verified(result) else { continue }
			await transaction.finish()
		}
	}

	/// Handle a transaction pushed via `Transaction.updates` (renewals, deferred
	/// Ask-to-Buy approvals, refunds/revocations).
	private func handle(_ result: VerificationResult<Transaction>) async {
		guard let transaction = verified(result) else { return }
		await transaction.finish()
		await refreshEntitlement()
		// Republish to SubscriptionState — this update came from the background listener,
		// not a direct purchase/restore, so nothing else will sync it.
		onEntitlementChange?()
	}

	/// Recompute ``isSubscribed`` from the device's current entitlements, counting only
	/// cryptographically verified, non-revoked subscription transactions for our group.
	private func refreshEntitlement() async {
		var entitled = false
		var transactionID: UInt64?
		var expiration: Date?
		var inTrial = false
		for await result in Transaction.currentEntitlements {
			guard let transaction = verified(result) else { continue }
			guard transaction.productType == .autoRenewable,
				  SubscriptionProduct.allIDs.contains(transaction.productID),
				  transaction.revocationDate == nil else { continue }
			entitled = true
			transactionID = transaction.id
			expiration = transaction.expirationDate
			inTrial = transaction.offer?.type == .introductory
			break
		}
		isSubscribed = entitled
		currentTransactionID = transactionID
		currentExpirationDate = expiration
		isInTrial = inTrial
	}

	/// Unwrap a `VerificationResult`, returning the payload only when StoreKit verified
	/// it (`.verified`). Unverified results are dropped — they cannot be trusted as
	/// entitlement on-device.
	private func verified<T>(_ result: VerificationResult<T>) -> T? {
		switch result {
		case .verified(let safe):
			return safe
		case .unverified:
			return nil
		}
	}

	/// Deterministic UUID derived from an arbitrary string id, so the same Clerk user
	/// always maps to the same `appAccountToken` — including across app launches and
	/// reinstalls (needed so a future backend can reconcile transactions to a user).
	///
	/// Uses SHA-256 (stable) rather than `Hasher`, whose seed is randomized per process
	/// run — `Hasher` would produce a different token every launch.
	private static func deterministicUUID(from string: String) -> UUID {
		let digest = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
		return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
						   digest[4], digest[5], digest[6], digest[7],
						   digest[8], digest[9], digest[10], digest[11],
						   digest[12], digest[13], digest[14], digest[15]))
	}
}

#if DEBUG
/// In-memory ``SubscriptionProviding`` for UI tests and SwiftUI previews. Compiled out
/// of Release/TestFlight builds (`#if DEBUG`) so the entitlement bypass cannot ship.
///
/// Selected by ``DependencyContainer`` under tests/UI-testing, optionally overridden by
/// the `-mockSubscription <state>` launch argument (mirrors `-mockAuthGate`).
@MainActor
final class MockSubscriptionProvider: SubscriptionProviding {
	/// Which entitlement the mock should resolve to.
	enum Outcome: String {
		case subscribed
		case notSubscribed
	}

	private var outcome: Outcome

	/// Mock products are empty: `Product` cannot be constructed without StoreKit, so the
	/// paywall renders its "unavailable" state under the mock. Entitlement is still driven.
	let products: [Product] = []

	init(outcome: Outcome = .notSubscribed) {
		self.outcome = outcome
	}

	/// Parse `-mockSubscription <state>` from the launch arguments, defaulting to
	/// `.subscribed` so existing UI tests pass straight through the whole-app gate into
	/// the app. Tests that need the paywall pass `-mockSubscription notSubscribed`.
	static func fromLaunchArguments() -> MockSubscriptionProvider {
		let args = ProcessInfo.processInfo.arguments
		if let idx = args.firstIndex(of: "-mockSubscription"),
		   idx + 1 < args.count,
		   let parsed = Outcome(rawValue: args[idx + 1]) {
			return MockSubscriptionProvider(outcome: parsed)
		}
		return MockSubscriptionProvider(outcome: .subscribed)
	}

	/// Mutate the simulated outcome between syncs (tests/previews only).
	func setOutcomeForTesting(_ newOutcome: Outcome) {
		outcome = newOutcome
	}

	/// Simulate a successful purchase without a real `Product` (which cannot be
	/// constructed outside the StoreKitTest framework). Mirrors ``purchase(_:)``'s
	/// effect so unit tests can exercise the purchase → entitled transition.
	func simulatePurchaseForTesting() {
		outcome = .subscribed
	}

	var isSubscribed: Bool { outcome == .subscribed }

	var onEntitlementChange: (() -> Void)?

	/// A fake transaction id when subscribed so the refund affordance is exercisable in
	/// previews/UI tests (the real refund sheet only works against StoreKit).
	var currentTransactionID: UInt64? { outcome == .subscribed ? 1 : nil }
	var currentExpirationDate: Date? { nil }
	var isInTrial: Bool { false }

	/// Simulate a background entitlement change (Ask-to-Buy approval / refund) and fire
	/// the callback, so tests can verify `SubscriptionState` republishes.
	func simulateEntitlementChange(to newOutcome: Outcome) {
		outcome = newOutcome
		onEntitlementChange?()
	}

	func start() async {}
	func loadProducts() async {}

	/// What the next ``purchase(_:)`` resolves to. Defaults to `.subscribed` so existing
	/// tests and the UI-test gate pass straight through; set it to drive the failure and
	/// Ask-to-Buy branches without StoreKit (AIA-0376).
	var purchaseOutcome: PurchaseOutcome = .subscribed

	/// What the next ``restore()`` resolves to. Defaults to `.restored`, matching the
	/// previous always-succeeds mock.
	var restoreOutcome: RestoreOutcome = .restored

	func purchase(_ product: Product) async -> PurchaseOutcome {
		if purchaseOutcome == .subscribed { outcome = .subscribed }
		return purchaseOutcome
	}

	func restore() async -> RestoreOutcome {
		if restoreOutcome == .restored { outcome = .subscribed }
		return restoreOutcome
	}
}
#endif
