//
//  EntitlementTransaction.swift
//  AI Archeology
//
//  The seam where StoreKit meets the entitlement decision (AIA-0530).
//

import Foundation
import StoreKit

/// The six facts ``EntitlementCandidate`` reads off a StoreKit transaction.
///
/// Exists so the projection below can be driven by a test. `StoreKit.Transaction` cannot be
/// constructed — its storage is an internal `BackingValue`, it has no public initializer, and it is
/// not `Decodable` — and `SKTestSession` cannot mint one either, its control channel being
/// non-functional on iOS 26.5 (AIA-0518). A protocol is the only way in.
///
/// `Transaction` supplies five of these already, under exactly these names (`id` via
/// `Identifiable`), which is what keeps its conformance to a single line.
///
/// Note the offer is exposed as ``offerType`` rather than as `Transaction.Offer`: that type has no
/// public initializer, so a test fake could not produce one. `Transaction.OfferType` and
/// `Product.ProductType` both do, which is what makes this seam viable at all.
protocol EntitlementTransaction {
	var productID: String { get }
	var id: UInt64 { get }
	var productType: Product.ProductType { get }
	/// Non-`nil` once Apple has granted a refund.
	var revocationDate: Date? { get }
	var expirationDate: Date? { get }
	var offerType: Transaction.OfferType? { get }
}

extension Transaction: EntitlementTransaction {
	/// The only member `Transaction` does not already satisfy.
	///
	/// **This line is the residual untested surface of the whole entitlement path.** Everything it
	/// feeds is covered; it is not, because reaching it needs a real transaction. Keep it a pure
	/// alias — any logic added here becomes invisible to the suite.
	var offerType: Transaction.OfferType? { offer?.type }
}

extension EntitlementCandidate {
	/// Project a verified StoreKit transaction onto the facts the entitlement decision reads.
	///
	/// The only place `Transaction` and ``EntitlementResolver`` meet. Every judgement made here —
	/// what counts as a subscription, what counts as a trial, whether a refund is carried through —
	/// is now reachable from a test via ``EntitlementTransaction`` (AIA-0530).
	init(_ transaction: some EntitlementTransaction) {
		self.init(
			productID: transaction.productID,
			transactionID: transaction.id,
			isAutoRenewable: transaction.productType == .autoRenewable,
			revocationDate: transaction.revocationDate,
			expirationDate: transaction.expirationDate,
			isIntroductoryOffer: transaction.offerType == .introductory
		)
	}
}
