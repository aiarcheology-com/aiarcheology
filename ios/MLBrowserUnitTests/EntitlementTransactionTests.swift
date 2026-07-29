//
//  EntitlementTransactionTests.swift
//  MLBrowserUnitTests
//
//  AIA-0530: the projection where StoreKit meets the entitlement decision.
//
//  Previously the only untested link in the chain, and the one that mattered most: everything
//  downstream receives `EntitlementCandidate` values, so a projection that stopped carrying
//  `revocationDate` would re-grant access to every refunded user with all 33 AIA-0518 tests green.
//

import StoreKit
import XCTest
@testable import ML_Browser

/// Stands in for `StoreKit.Transaction`, which cannot be constructed: internal storage, no public
/// initializer, not `Decodable`. `Product.ProductType` and `Transaction.OfferType` *are*
/// constructible, which is what makes this fake possible at all.
private struct FakeTransaction: EntitlementTransaction {
	var productID = SubscriptionProduct.monthly
	var id: UInt64 = 1
	var productType: Product.ProductType = .autoRenewable
	var revocationDate: Date?
	var expirationDate: Date?
	var offerType: Transaction.OfferType?
}

final class EntitlementTransactionTests: XCTestCase {

	private let expiryDate = Date(timeIntervalSince1970: 1_800_000_000)
	private let revokedDate = Date(timeIntervalSince1970: 1_700_000_000)

	// MARK: - Identity carried through

	func testProjection_CarriesProductIDAndTransactionID() {
		let candidate = EntitlementCandidate(FakeTransaction(productID: "com.example.other", id: 8_675_309))

		XCTAssertEqual(candidate.productID, "com.example.other")
		XCTAssertEqual(candidate.transactionID, 8_675_309)
	}

	// MARK: - Refund safety

	/// The link this ticket exists for. A refund reaches the app as a revocation date on the
	/// transaction; if the projection drops it, `EntitlementResolver` never sees a reason to
	/// withhold access and a refunded user stays subscribed forever.
	func testProjection_CarriesRevocationDate() {
		let candidate = EntitlementCandidate(FakeTransaction(revocationDate: revokedDate))

		XCTAssertEqual(candidate.revocationDate, revokedDate)
	}

	/// The paired negative: a live transaction must not acquire a revocation date from nowhere,
	/// which would lock out everyone who has paid.
	func testProjection_LiveTransaction_HasNoRevocationDate() {
		XCTAssertNil(EntitlementCandidate(FakeTransaction(revocationDate: nil)).revocationDate)
	}

	// MARK: - Product type

	func testProjection_AutoRenewableSubscription_IsAutoRenewable() {
		XCTAssertTrue(EntitlementCandidate(FakeTransaction(productType: .autoRenewable)).isAutoRenewable)
	}

	/// Every other product kind must not read as a subscription — a consumable carrying our
	/// product id would otherwise unlock the app permanently for a one-off purchase.
	func testProjection_OtherProductTypes_AreNotAutoRenewable() {
		for productType: Product.ProductType in [.consumable, .nonConsumable, .nonRenewable] {
			let candidate = EntitlementCandidate(FakeTransaction(productType: productType))

			XCTAssertFalse(candidate.isAutoRenewable, "\(productType.rawValue) must not count as a subscription")
		}
	}

	// MARK: - Expiry

	func testProjection_CarriesExpirationDate() {
		XCTAssertEqual(EntitlementCandidate(FakeTransaction(expirationDate: expiryDate)).expirationDate, expiryDate)
	}

	/// `nil` is a real answer, not a missing one, and must survive as `nil` rather than becoming
	/// a fabricated date the UI would show as a renewal.
	func testProjection_NoExpirationDate_StaysNil() {
		XCTAssertNil(EntitlementCandidate(FakeTransaction(expirationDate: nil)).expirationDate)
	}

	// MARK: - Trial detection

	func testProjection_IntroductoryOffer_IsIntroductory() {
		XCTAssertTrue(EntitlementCandidate(FakeTransaction(offerType: .introductory)).isIntroductoryOffer)
	}

	/// The offer types that are *not* the free trial. Reporting a promotional or win-back offer
	/// as introductory would tell a paying subscriber they are still on trial.
	func testProjection_OtherOfferTypes_AreNotIntroductory() {
		for offerType: Transaction.OfferType in [.promotional, .code, .winBack] {
			let candidate = EntitlementCandidate(FakeTransaction(offerType: offerType))

			XCTAssertFalse(candidate.isIntroductoryOffer, "offer type \(offerType.rawValue) must not read as a trial")
		}
	}

	/// No offer at all is the ordinary paid subscription.
	func testProjection_NoOffer_IsNotIntroductory() {
		XCTAssertFalse(EntitlementCandidate(FakeTransaction(offerType: nil)).isIntroductoryOffer)
	}

	// MARK: - End to end through the resolver

	/// The projection and the decision together, which is what actually gates the app: a revoked
	/// transaction must produce no entitlement even though every other field says it should.
	func testProjection_RevokedTransaction_ResolvesToNoEntitlement() {
		let revoked = EntitlementCandidate(FakeTransaction(revocationDate: revokedDate, expirationDate: expiryDate))

		XCTAssertNil(EntitlementResolver.resolve([revoked]))
	}

	func testProjection_ActiveTransaction_ResolvesToAnEntitlement() {
		let active = EntitlementCandidate(FakeTransaction(id: 77, expirationDate: expiryDate, offerType: .introductory))

		XCTAssertEqual(
			EntitlementResolver.resolve([active]),
			ResolvedEntitlement(transactionID: 77, expirationDate: expiryDate, isInTrial: true)
		)
	}
}
