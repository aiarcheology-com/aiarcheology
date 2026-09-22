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

extension SubscriptionStatusState {
	/// Collapse StoreKit's renewal states into the three this app distinguishes (AIA-0782).
	///
	/// `.inGracePeriod` joins `.subscribed` because Apple keeps serving those customers while it
	/// retries the payment; `.inBillingRetryPeriod` does **not**, because by then access has
	/// lapsed. The `default` arm — `RenewalState` is a struct of static values, so there is no
	/// `@unknown default` to write — maps to `.other`: a state StoreKit adds later must not be
	/// read as an entitlement by a build that has never heard of it.
	init(_ state: Product.SubscriptionInfo.RenewalState) {
		switch state {
		case .subscribed: self = .subscribed
		case .inGracePeriod: self = .inGracePeriod
		case .expired, .inBillingRetryPeriod, .revoked: self = .other
		default: self = .other
		}
	}
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

	/// How the provider learns which account to tag a purchase with (AIA-0518).
	///
	/// Injected rather than read from `Clerk.shared` at the point of use: touching that
	/// singleton **traps** when Clerk was never configured, which is the state in every test
	/// process (`DependencyContainer.usesMockAuth` exists for the same reason). Before this,
	/// any test that reached ``purchase(_:)`` crashed with a signal trap before StoreKit was
	/// ever consulted, which is why the money path had no coverage at all.
	///
	/// The default is the production reader, so behaviour outside tests is unchanged.
	private let accountIdentifierSource: @MainActor () -> String?

	/// Where the entitlement candidates come from (AIA-0518).
	///
	/// Injected for the same reason as ``accountIdentifierSource``: the production reader walks
	/// `Transaction.currentEntitlements`, and `Transaction` cannot be constructed outside
	/// `StoreKitTest` — whose control channel is non-functional on iOS 26.5. Without this seam
	/// the four published properties below are wired up by code no test can execute, so an
	/// inverted `isSubscribed`, a swapped transaction id, or a dropped expiry would all ship
	/// green. What stays untestable is only the projection itself (`EntitlementCandidate.init`)
	/// and the `verified()` drop, which genuinely need a real `Transaction`.
	private let entitlementSource: @MainActor () async -> [EntitlementCandidate]

	init(
		accountIdentifierSource: (@MainActor () -> String?)? = nil,
		entitlementSource: (@MainActor () async -> [EntitlementCandidate])? = nil
	) {
		self.accountIdentifierSource = accountIdentifierSource ?? Self.clerkAccountIdentifier
		self.entitlementSource = entitlementSource ?? Self.currentEntitlementCandidates
	}

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
		} catch is CancellationError {
			// Not a failure: the view that asked went away mid-fetch, which is ordinary now that
			// Settings loads products for its account footer and can be dismissed at any moment.
			// Logged at debug because `error` here would raise a remote event every time someone
			// closes Settings quickly.
			LoggingPolicy.debug("Product load cancelled — keeping whatever was already loaded.", logger: .networking)
		} catch let error as URLError where error.code == .cancelled {
			// The same cancellation, surfaced through the URL loading system rather than Swift
			// concurrency. StoreKit can report it either way, so both are treated as ordinary.
			LoggingPolicy.debug("Product load cancelled — keeping whatever was already loaded.", logger: .networking)
		} catch {
			LoggingPolicy.error(
				"Failed to load subscription products: \(error.localizedDescription)",
				logger: .networking
			)
			// Deliberately keeps whatever was already loaded. A failed refresh says nothing about
			// the products fetched earlier, and this now has more than one caller: Settings resolves
			// the same products to decide what its footer may promise, and the paywall is presented
			// as a sheet from that very screen. Clearing here republished an empty list to every
			// observer, so a fetch that failed — or merely got cancelled when its view went away —
			// could swap a working Subscribe button for "subscriptions are not available right now"
			// under the user's finger. Only a successful fetch replaces the list.
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
				// Not necessarily a change of mind — see ``outcomeAfterCancellation(statusCandidates:)``.
				return await outcomeAfterCancellation {
					await Self.statusCandidates(for: product)
				}
			@unknown default:
				LoggingPolicy.warning("Unknown purchase result.", logger: .state)
				return .failed
			}
		} catch {
			LoggingPolicy.error("Purchase failed: \(error.localizedDescription)", logger: .state)
			return .failed
		}
	}

	/// What a `.userCancelled` purchase actually means (AIA-0782).
	///
	/// StoreKit reports the same `.userCancelled` for two different events, and the app used to
	/// treat both as the second:
	///
	/// 1. The customer dismissed a real purchase sheet. Ordinary; nothing changed.
	/// 2. `product.purchase()` asked the App Store, was told **this Apple Account already owns the
	///    subscription**, and showed its own "You are currently subscribed" dialog instead of a
	///    purchase sheet. Cancelling *that* also returns `.userCancelled` — and the store had just
	///    confirmed ownership, which the old mapping threw away. The customer landed back on the
	///    wall with the one obvious button leading nowhere: the dead end AIA-0782 reports, and the
	///    exact path an App Review tester on a sandbox account that already subscribed walks.
	///
	/// StoreKit does not distinguish the two, so the entitlement is re-read instead of guessed at.
	/// It costs a local read and prompts for nothing — deliberately **not** `AppStore.sync()`,
	/// which asks for App Store credentials and is therefore restore-only, per Apple's guidance
	/// and per ``restore()``.
	///
	/// Internal rather than private so a test can drive the whole decision: ``purchase(_:)`` needs
	/// a `Product`, which cannot be constructed outside `StoreKitTest`, so the branch is otherwise
	/// unreachable — the same reason ``refreshEntitlement()`` and ``purchaseOptions()`` are
	/// internal.
	///
	/// Honest about its reach: case 2 is only rescued when the store's answer has landed in the
	/// **local** entitlements by the time this runs. Where it has not, the outcome is `.cancelled`
	/// — exactly today's behaviour, so this can only add a way out, never take one away.
	func outcomeAfterCancellation(
		statusCandidates: () async -> [SubscriptionStatusCandidate]
	) async -> PurchaseOutcome {
		await refreshEntitlement()
		if isSubscribed {
			LoggingPolicy.info(
				"Purchase dialog was dismissed but the account is entitled — treating it as subscribed.",
				logger: .state
			)
			return .subscribed
		}
		guard SubscriptionStatusResolver.reportsRestorableSubscription(await statusCandidates()) else {
			return .cancelled
		}
		LoggingPolicy.info(
			"Purchase dialog was dismissed with no local entitlement, but the store reports an"
				+ " active subscription — recommending Restore.",
			logger: .state
		)
		return .restoreRecommended
	}

	/// The production status reader. Only ever called through the closure ``purchase(_:)`` hands to
	/// ``outcomeAfterCancellation(statusCandidates:)``.
	///
	/// Maps rather than filters: whether an unverified status counts is ``SubscriptionStatusResolver``'s
	/// rule, and a reader that silently dropped them would move that rule somewhere no test can see it.
	/// `unsafePayloadValue` is safe here for exactly that reason — the product id is read for the
	/// resolver to judge, never as proof of anything on its own.
	///
	/// A thrown query is an answer, not a crash: the store could not be reached, which is not
	/// evidence of a subscription. Logged and reported as nothing found, so the customer gets
	/// today's silent `.cancelled` rather than a claim the app cannot support.
	private static func statusCandidates(for product: Product) async -> [SubscriptionStatusCandidate] {
		guard let subscription = product.subscription else { return [] }
		do {
			return try await subscription.status.map { status in
				SubscriptionStatusCandidate(
					productID: status.transaction.unsafePayloadValue.productID,
					state: SubscriptionStatusState(status.state),
					isVerified: { if case .verified = status.transaction { return true } else { return false } }()
				)
			}
		} catch {
			LoggingPolicy.warning(
				"Subscription status query failed after a cancelled purchase: \(error.localizedDescription)",
				logger: .networking
			)
			return []
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
	///
	/// Internal rather than private so a test can assert what a purchase would actually be
	/// tagged with. Its only production caller is ``purchase(_:)``, which needs a `Product` and
	/// is therefore unreachable from a test — leaving this the sole way to catch a regression
	/// that silently stops tagging purchases at all (AIA-0518).
	func purchaseOptions() -> Set<Product.PurchaseOption> {
		guard let token = appAccountToken() else { return [] }
		return [.appAccountToken(token)]
	}

	private func appAccountToken() -> UUID? {
		AppAccountToken.make(from: accountIdentifierSource())
	}

	/// The production account reader. Only ever called through ``accountIdentifierSource``,
	/// so a test can substitute it without configuring Clerk.
	private static func clerkAccountIdentifier() -> String? {
		#if canImport(ClerkKit)
		return Clerk.shared.user?.id
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
		guard let transaction = verified(result) else {
			// Not silent: on My Mac the StoreKit Testing certificate is untrusted, so even
			// genuine updates (e.g. a refund revocation) fail verification here — dropping
			// them without a trace made "the update never arrived" indistinguishable from
			// "it arrived and was rejected" (AIA-0448).
			LoggingPolicy.warning("Transaction update failed verification — dropped.", logger: .state)
			return
		}
		// A granted refund arrives HERE, as a revocation — not as any callback on the screen
		// that requested it. This line is the only breadcrumb tying the entitlement flip that
		// follows back to its cause (AIA-0448).
		LoggingPolicy.info(
			"Transaction update: id=\(transaction.id) product=\(transaction.productID)"
				+ " revoked=\(transaction.revocationDate != nil)",
			logger: .state
		)
		await transaction.finish()
		await refreshEntitlement()
		// Republish to SubscriptionState — this update came from the background listener,
		// not a direct purchase/restore, so nothing else will sync it.
		onEntitlementChange?()
	}

	/// Recompute ``isSubscribed`` from the device's current entitlements, counting only
	/// cryptographically verified, non-revoked subscription transactions for our group.
	///
	/// Reading the candidates and deciding on them are now separate: the read needs StoreKit,
	/// the decision is ``EntitlementResolver``'s, and publishing the result is this method's.
	/// Only the read is beyond a test's reach (AIA-0518).
	///
	/// Internal rather than private so a test can drive it with an injected `entitlementSource`.
	/// Its production callers all make a real StoreKit round-trip first — `restore()` calls
	/// `AppStore.sync()`, `start()` drains `Transaction.unfinished` — which a unit test must not
	/// do; calling this directly is what keeps the publication wiring testable without one.
	func refreshEntitlement() async {
		let resolved = EntitlementResolver.resolve(await entitlementSource())
		isSubscribed = resolved != nil
		currentTransactionID = resolved?.transactionID
		currentExpirationDate = resolved?.expirationDate
		isInTrial = resolved?.isInTrial ?? false
	}

	/// The production candidate reader. Only ever called through ``entitlementSource``.
	///
	/// Collects before resolving rather than deciding inside the loop, so the "skip an
	/// ineligible entry and keep scanning" rule lives in one testable place. The sequence holds
	/// the latest transaction per product, so materializing it is not a cost.
	private static func currentEntitlementCandidates() async -> [EntitlementCandidate] {
		var candidates: [EntitlementCandidate] = []
		for await result in Transaction.currentEntitlements {
			// Unverified results are dropped — they cannot be trusted as entitlement on-device.
			guard case .verified(let transaction) = result else { continue }
			candidates.append(EntitlementCandidate(transaction))
		}
		return candidates
	}

	// MARK: - StoreKit bridging

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

	/// Whether the simulated entitlement is the introductory free trial. Stored rather than
	/// hardcoded `false` so the trial axis is reachable at all — while it was a constant, no
	/// test or preview could distinguish a trial subscriber from a paying one. Defaults to
	/// `false`, so every existing caller keeps the exact behaviour it had.
	/// Backing store. Read through ``isInTrial``, which also requires an active entitlement — a
	/// trial that outlives the subscription is a state StoreKit cannot produce, and letting tests
	/// observe an "unsubscribed trial user" would let them assert on nonsense.
	private var isInTrialFlag: Bool

	init(outcome: Outcome = .notSubscribed, isInTrial: Bool = false) {
		self.outcome = outcome
		self.isInTrialFlag = isInTrial
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

	/// A fake transaction id when subscribed, so the published-field contract holds on the mock
	/// path too: entitled implies an id, unentitled implies none.
	var currentTransactionID: UInt64? { outcome == .subscribed ? 1 : nil }
	var currentExpirationDate: Date? { nil }
	var isInTrial: Bool { isInTrialFlag && outcome == .subscribed }

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
		applyConfiguredPurchaseOutcome()
	}

	/// Applies ``purchaseOutcome`` without talking to StoreKit.
	///
	/// Unit tests call this directly. ``purchase(_:)`` cannot be invoked offline: it requires a
	/// `Product`, and constructing one goes through `Product.products(for:)`.
	func applyConfiguredPurchaseOutcome() -> PurchaseOutcome {
		if purchaseOutcome == .subscribed { outcome = .subscribed }
		return purchaseOutcome
	}

	func restore() async -> RestoreOutcome {
		if restoreOutcome == .restored { outcome = .subscribed }
		return restoreOutcome
	}
}
#endif
