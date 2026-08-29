//
//  EntitlementResolver.swift
//  AI Archeology
//
//  The subscription entitlement decision, lifted out of StoreKit so it can be tested (AIA-0518).
//

import Foundation

/// The facts the entitlement decision actually reads from one StoreKit transaction.
///
/// A plain value rather than `StoreKit.Transaction`, which cannot be constructed outside the
/// `StoreKitTest` framework — and that framework's control channel is non-functional on
/// iOS 26.5 (`SKTestSession` returns `notEntitled` for every state-changing call, identically
/// from the CLI, from the Xcode IDE, and from a UI test that creates the session before the app
/// launches). Mirroring the fields here is what makes the rules below reachable from a test at
/// all; before this they had no coverage in any form.
struct EntitlementCandidate: Equatable {
	let productID: String
	let transactionID: UInt64
	/// Only auto-renewable subscriptions grant access. A consumable or non-consumable carrying
	/// one of our product ids must not.
	let isAutoRenewable: Bool
	/// Non-`nil` once Apple has granted a refund. A revocation is how losing access arrives —
	/// there is no callback on the screen that requested the refund (AIA-0448).
	let revocationDate: Date?
	let expirationDate: Date?
	let isIntroductoryOffer: Bool
}

/// The entitlement a set of candidates resolves to.
struct ResolvedEntitlement: Equatable {
	let transactionID: UInt64
	let expirationDate: Date?
	let isInTrial: Bool
}

/// Decides whether the device's current entitlements grant access, and on which transaction.
///
/// Pure and synchronous on purpose: this is the rule set that decides who has paid, so it is the
/// part that most needs to be exhaustively testable, and it is the part that needs StoreKit least.
enum EntitlementResolver {

	/// The first candidate that grants access, or `nil` when none does.
	///
	/// All three conditions must hold, and a candidate failing any of them is **skipped rather
	/// than terminating the scan** — a refunded transaction sitting ahead of a live one must not
	/// mask it, which is the case a naive "look at the first entitlement" would get wrong.
	///
	/// This behaviour is carried over from the loop that used to live in the provider, not
	/// introduced here: the extraction made the rule testable, it did not change it.
	///
	/// Order is the caller's: `Transaction.currentEntitlements` yields at most one entry per
	/// product, so first-eligible-wins is a total rule in practice rather than a tie-break.
	static func resolve(
		_ candidates: some Sequence<EntitlementCandidate>,
		productIDs: Set<String> = Set(SubscriptionProduct.allIDs)
	) -> ResolvedEntitlement? {
		for candidate in candidates {
			guard candidate.isAutoRenewable,
				  productIDs.contains(candidate.productID),
				  candidate.revocationDate == nil else { continue }
			return ResolvedEntitlement(
				transactionID: candidate.transactionID,
				expirationDate: candidate.expirationDate,
				isInTrial: candidate.isIntroductoryOffer
			)
		}
		return nil
	}
}

/// How the App Store answers "is there an active subscription for this group", reduced to the
/// facts the decision reads (AIA-0782).
///
/// A plain value for the same reason ``EntitlementCandidate`` is one: the StoreKit types behind it
/// — `Product.SubscriptionInfo.Status` and the `VerificationResult<Transaction>` it carries —
/// cannot be constructed in a test, so a rule written against them is a rule nothing can check.
struct SubscriptionStatusCandidate: Equatable {
	let productID: String
	let state: SubscriptionStatusState
	/// Whether StoreKit verified the transaction backing this status. An unverified status is not
	/// evidence of anything: it is the same signature check `currentEntitlements` results get, and
	/// the same answer — dropped.
	let isVerified: Bool
}

/// The subscription states this app distinguishes, mapped from StoreKit's `RenewalState`.
///
/// Deliberately three-valued rather than mirroring every StoreKit case. Only two states mean the
/// store is holding something a Restore would surface; everything else — expired, in billing
/// retry, revoked, or whatever StoreKit adds next — is the same answer here, and collapsing them
/// keeps this file free of `import StoreKit` and therefore testable.
enum SubscriptionStatusState: Equatable {
	/// An active subscription.
	case subscribed
	/// Billing failed but Apple is still serving the subscription. Apple's guidance is that these
	/// customers keep access, so this counts.
	case inGracePeriod
	/// Anything else. Not evidence of an active subscription.
	case other
}

/// Whether the App Store is reporting a subscription that an explicit Restore would surface.
///
/// The second half of AIA-0782's answer, and the reason it exists: when a purchase is cancelled and
/// the *local* entitlements are still empty, this is the only thing left that can tell the customer
/// what to do — and doing it wrong means telling someone who simply changed their mind that they
/// already subscribed.
///
/// It deliberately claims **less** than "you own this". A subscription-group status may describe a
/// Family Sharing entitlement, so the honest statement is that the store reports an active
/// subscription for this app, not that this Apple Account bought one.
enum SubscriptionStatusResolver {

	/// True when at least one candidate is a verified, recognised product in an active state.
	///
	/// Every clause is load-bearing and each is the one a naive version drops: an unverified status
	/// is unsigned data; a status for a product this app does not sell says nothing about access to
	/// it; and `.other` covers the expired and billing-retry entries that sit in the same array as
	/// live ones — a customer whose subscription lapsed must be sold one, not sent to Restore.
	static func reportsRestorableSubscription(
		_ candidates: some Sequence<SubscriptionStatusCandidate>,
		productIDs: Set<String> = Set(SubscriptionProduct.allIDs)
	) -> Bool {
		candidates.contains { candidate in
			candidate.isVerified
				&& productIDs.contains(candidate.productID)
				&& (candidate.state == .subscribed || candidate.state == .inGracePeriod)
		}
	}
}
