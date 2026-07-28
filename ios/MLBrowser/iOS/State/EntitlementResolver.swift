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
