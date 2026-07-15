//
//  SubscriptionState.swift
//  AI Archeology
//
//  Subscription / entitlement state (AIA-0343).
//

import Foundation
import StoreKit
import OSLog

/// What a purchase attempt did, in the terms the UI has to act on (AIA-0376).
///
/// A `Bool` cannot express this: `.userCancelled` and a failed verification are both "not
/// subscribed", but one is the user's own choice and the other is an error they must see.
/// Collapsing them is what made the paywall fall silent on failure.
///
/// There is deliberately no `unverified` case. An unverified transaction and a thrown error
/// are the same event to the user — "it didn't go through" — and the provider logs them
/// distinctly, so a separate case would be API surface with no consumer.
enum PurchaseOutcome: Equatable {
	/// Verified purchase. Dismiss the paywall.
	case subscribed
	/// The user dismissed Apple's sheet. Say nothing: they know what they did.
	case cancelled
	/// Ask-to-Buy / SCA. Not an error — approval arrives later via `Transaction.updates`.
	case pending
	/// Verification failed, StoreKit threw, or an unknown result arrived.
	case failed
}

/// What a restore attempt did (AIA-0376). Separate from ``PurchaseOutcome`` because
/// "no purchases to restore" is a normal answer, not a failure.
enum RestoreOutcome: Equatable {
	/// An entitlement was found. The gate re-renders on its own.
	case restored
	/// The store answered and the account simply owns nothing.
	case nothingToRestore
	/// The store could not be reached and no local entitlement was found either.
	case failed
}

/// Abstraction over the StoreKit billing backend so ``SubscriptionState`` can be
/// unit-tested and UI-tested without StoreKit or App Store Connect.
///
/// All members are `@MainActor`: the production implementation
/// (``StoreKitSubscriptionProvider``) drives UI-bound state and StoreKit's
/// main-actor-friendly async APIs. Named `…Provider` (not `…Service`) so the
/// Harmonize "services are actors" rule does not apply — see ``AuthProviding``
/// for the same reasoning.
@MainActor
protocol SubscriptionProviding: AnyObject {
	/// Called whenever the entitlement changes *outside* a direct purchase/restore call —
	/// i.e. from the background `Transaction.updates` listener (Ask-to-Buy approval,
	/// renewal, refund/revocation). ``SubscriptionState`` wires this to its `sync()` so
	/// those changes reach the published state and the gate re-renders.
	var onEntitlementChange: (() -> Void)? { get set }

	/// True when ``Transaction/currentEntitlements`` contains a verified, active
	/// subscription. This on-device check is the Phase-A source of truth — there
	/// is no backend.
	var isSubscribed: Bool { get }

	/// The subscription products available to purchase (may be empty if the
	/// product fetch failed or App Store Connect isn't configured yet).
	var products: [Product] { get }

	/// The StoreKit transaction id backing the current entitlement, if any — used to
	/// drive Apple's in-app refund request sheet. `nil` when not subscribed.
	var currentTransactionID: UInt64? { get }

	/// When the current subscription period ends (renewal or expiry date), if known.
	var currentExpirationDate: Date? { get }

	/// True while the active entitlement is the introductory free trial.
	var isInTrial: Bool { get }

	/// Install the `Transaction.updates` listener and drain any unfinished /
	/// pending transactions (Ask-to-Buy, interrupted purchases). Call once at app
	/// launch, BEFORE any purchase UI is shown.
	func start() async

	/// Load the subscription products from the store. Degrades gracefully (logs +
	/// leaves ``products`` empty) on failure; never throws.
	func loadProducts() async

	/// Purchase a product.
	///
	/// Deliberately **not** `@discardableResult`: dropping this value is the bug in
	/// AIA-0376, so the compiler is the guard against it recurring.
	func purchase(_ product: Product) async -> PurchaseOutcome

	/// Restore purchases by re-syncing with the App Store, then recompute entitlement.
	///
	/// Deliberately **not** `@discardableResult` — see ``purchase(_:)``.
	func restore() async -> RestoreOutcome
}

/// Owns the subscription/entitlement state for the UI (mirrors ``AuthState``).
/// Views observe ``isSubscribed`` and ``products`` and send purchase/restore intents.
@MainActor
final class SubscriptionState: ObservableObject {
	/// True when the user holds a verified, active subscription entitlement.
	@Published private(set) var isSubscribed = false

	/// Products available on the paywall.
	@Published private(set) var products: [Product] = []

	/// Transaction id backing the current entitlement (for the refund request sheet).
	@Published private(set) var currentTransactionID: UInt64?

	/// End of the current subscription period (renewal/expiry date), if known.
	@Published private(set) var currentExpirationDate: Date?

	/// True while the active entitlement is the introductory free trial.
	@Published private(set) var isInTrial = false

	private let provider: SubscriptionProviding

	/// Captured **once** at construction and deliberately not observed (AIA-0350).
	/// `isPaymentsEnabled` applies at a session boundary only: `SubscriptionGateView` is
	/// the app root, so applying a mid-session flip would either drop a paywall on a user
	/// who is mid-detection or release an unpaid user from it. A remote change therefore
	/// takes effect on the next launch.
	private let isPaymentsEnabled: Bool

	init(provider: SubscriptionProviding, isPaymentsEnabled: Bool) {
		self.provider = provider
		self.isPaymentsEnabled = isPaymentsEnabled
		// Republish when the background Transaction.updates listener changes entitlement
		// (Ask-to-Buy approval, renewal, refund/revocation) — otherwise the gate would
		// read a stale value until relaunch.
		provider.onEntitlementChange = { [weak self] in self?.sync() }
	}

	/// Whether a feature should be unlocked: requires both the payments flag and a
	/// live entitlement. This is the single gate the UI should consult.
	var isPremiumUnlocked: Bool {
		isPaymentsEnabled && isSubscribed
	}

	/// Whether the payments surface is enabled for this session. Views that need the flag
	/// itself (rather than entitlement) read this instead of a global.
	var isPaymentsSurfaceEnabled: Bool { isPaymentsEnabled }

	/// Install the transaction listener, drain pending transactions, and publish the
	/// initial entitlement. Call once at launch. Product loading is intentionally NOT
	/// done here — it's a network call and must not block app readiness; the paywall
	/// loads products when it appears (``loadProducts()``).
	func start() async {
		await provider.start()
		sync()
	}

	/// Load the purchasable products (network). Called when the paywall appears so a
	/// slow/offline App Store fetch never delays launch.
	func loadProducts() async {
		await provider.loadProducts()
		sync()
	}

	/// Purchase `product`, refresh published state, and hand the outcome back so the
	/// caller can tell a cancellation from a failure (AIA-0376).
	func purchase(_ product: Product) async -> PurchaseOutcome {
		let outcome = await provider.purchase(product)
		sync()
		return outcome
	}

	/// Restore purchases, refresh published state, and hand the outcome back.
	func restore() async -> RestoreOutcome {
		let outcome = await provider.restore()
		sync()
		return outcome
	}

	/// Pull the latest values from the provider into the published properties.
	private func sync() {
		products = provider.products
		currentTransactionID = provider.currentTransactionID
		currentExpirationDate = provider.currentExpirationDate
		isInTrial = provider.isInTrial
		setSubscribed(provider.isSubscribed)
	}

	private func setSubscribed(_ newValue: Bool) {
		guard isSubscribed != newValue else { return }
		isSubscribed = newValue
		LoggingPolicy.info("Subscription entitlement → \(newValue)", logger: .state)
	}
}
