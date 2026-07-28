//
//  EntitlementResolverTests.swift
//  MLBrowserUnitTests
//
//  AIA-0518: the entitlement decision — who has paid, and on which transaction.
//
//  This is the rule set the whole paywall rests on, and until now none of it was reachable from
//  a test: it lived inside a loop over `Transaction.currentEntitlements`, and `Transaction`
//  cannot be constructed outside `StoreKitTest` — whose control channel returns `notEntitled`
//  for every state-changing call on iOS 26.5 (measured identically from the command line, from
//  the Xcode IDE, and from a UI test creating the session before app launch).
//

import XCTest
@testable import ML_Browser

/// Fixed values so no assertion depends on the wall clock, and a foreign id that is not ours.
private let monthlyID = SubscriptionProduct.monthly
private let foreignID = "com.example.other.monthly"
private let expiryDate = Date(timeIntervalSince1970: 1_800_000_000)
private let revocationDate = Date(timeIntervalSince1970: 1_700_000_000)

/// A candidate that grants access, so each test varies exactly one field away from valid and
/// nothing passes or fails for a reason it did not mean to exercise.
private func candidate(
	productID: String = monthlyID,
	transactionID: UInt64 = 1,
	isAutoRenewable: Bool = true,
	revokedAt: Date? = nil,
	expiresAt: Date? = expiryDate,
	isIntroductoryOffer: Bool = false
) -> EntitlementCandidate {
	EntitlementCandidate(
		productID: productID,
		transactionID: transactionID,
		isAutoRenewable: isAutoRenewable,
		revocationDate: revokedAt,
		expirationDate: expiresAt,
		isIntroductoryOffer: isIntroductoryOffer
	)
}

final class EntitlementResolverTests: XCTestCase {

	// MARK: - Nothing to resolve

	func testResolve_NoCandidates_IsNotEntitled() {
		XCTAssertNil(EntitlementResolver.resolve([EntitlementCandidate]()))
	}

	// MARK: - The happy path

	func testResolve_ActiveSubscription_CarriesTransactionExpiryAndTrialFlag() {
		let resolved = EntitlementResolver.resolve([candidate(transactionID: 42)])

		XCTAssertEqual(
			resolved,
			ResolvedEntitlement(transactionID: 42, expirationDate: expiryDate, isInTrial: false)
		)
	}

	/// The expiry is passed through untouched, `nil` included — the provider publishes it as the
	/// renewal date, and inventing one would put a wrong date in front of the user.
	func testResolve_NoExpirationDate_ResolvesWithNilExpiry() {
		let resolved = EntitlementResolver.resolve([candidate(expiresAt: nil)])

		XCTAssertNotNil(resolved)
		XCTAssertNil(resolved?.expirationDate)
	}

	// MARK: - Each disqualifying condition, one at a time

	/// The refund path. A granted refund arrives as a revocation on the transaction, and it is
	/// the only signal that access must stop — nothing else in the app is told (AIA-0448).
	func testResolve_RevokedTransaction_IsNotEntitled() {
		XCTAssertNil(EntitlementResolver.resolve([candidate(revokedAt: revocationDate)]))
	}

	/// A product from another app / another group must never unlock this one.
	func testResolve_ForeignProductID_IsNotEntitled() {
		XCTAssertNil(EntitlementResolver.resolve([candidate(productID: foreignID)]))
	}

	/// Only auto-renewable subscriptions grant access. A consumable or non-consumable carrying
	/// one of our ids is not a subscription, whatever it is named.
	func testResolve_NonAutoRenewableProduct_IsNotEntitled() {
		XCTAssertNil(EntitlementResolver.resolve([candidate(isAutoRenewable: false)]))
	}

	// MARK: - Trial detection

	func testResolve_IntroductoryOffer_IsInTrial() {
		XCTAssertEqual(EntitlementResolver.resolve([candidate(isIntroductoryOffer: true)])?.isInTrial, true)
	}

	/// The paired negative, so the positive above cannot pass with the flag stuck on.
	func testResolve_PaidSubscription_IsNotInTrial() {
		XCTAssertEqual(EntitlementResolver.resolve([candidate(isIntroductoryOffer: false)])?.isInTrial, false)
	}

	// MARK: - Scanning rules

	/// The case a naive "inspect the first entitlement" gets wrong, and the reason the scan
	/// skips instead of stopping: a refunded transaction ahead of a live one must not mask it.
	/// Getting this backwards would lock a paying subscriber out of the app.
	func testResolve_RevokedBeforeActive_ResolvesToTheActiveOne() {
		let resolved = EntitlementResolver.resolve([
			candidate(transactionID: 1, revokedAt: revocationDate),
			candidate(transactionID: 2)
		])

		XCTAssertEqual(resolved?.transactionID, 2)
	}

	/// The same rule for the other two disqualifiers, so a future refactor cannot silently make
	/// only revocation skippable.
	func testResolve_IneligibleEntriesBeforeActive_AreSkippedNotFatal() {
		let resolved = EntitlementResolver.resolve([
			candidate(productID: monthlyID, transactionID: 1, isAutoRenewable: false),
			candidate(productID: foreignID, transactionID: 2),
			candidate(transactionID: 3)
		])

		XCTAssertEqual(resolved?.transactionID, 3)
	}

	/// With more than one eligible entitlement the first wins, deterministically — the published
	/// transaction id drives the refund sheet, so it must not vary run to run.
	func testResolve_MultipleEligible_ResolvesToTheFirst() {
		let resolved = EntitlementResolver.resolve([
			candidate(transactionID: 7, expiresAt: expiryDate),
			candidate(transactionID: 8, expiresAt: expiryDate.addingTimeInterval(86_400))
		])

		XCTAssertEqual(resolved?.transactionID, 7)
		XCTAssertEqual(resolved?.expirationDate, expiryDate)
	}

	/// Every entry disqualified is still "not entitled" rather than a partially-populated
	/// result — the provider derives `isSubscribed` from nil-ness alone.
	func testResolve_AllCandidatesIneligible_IsNotEntitled() {
		XCTAssertNil(EntitlementResolver.resolve([
			candidate(productID: monthlyID, transactionID: 1, isAutoRenewable: false),
			candidate(productID: foreignID, transactionID: 2),
			candidate(transactionID: 3, revokedAt: revocationDate)
		]))
	}

	// MARK: - Product set

	/// The default product set is the shipping one, not a test fixture: a resolver that stopped
	/// consulting `SubscriptionProduct.allIDs` would fail open in production while every test
	/// above — which only ever passes ids through that same default — kept passing.
	func testResolve_DefaultProductIDs_AreTheShippingSubscriptionIDs() {
		XCTAssertEqual(SubscriptionProduct.allIDs, [SubscriptionProduct.monthly])
		XCTAssertNotNil(EntitlementResolver.resolve([candidate(productID: SubscriptionProduct.monthly)]))
	}

	/// An explicitly narrowed product set still governs, so the parameter is not decorative —
	/// without this, `productIDs` could be ignored entirely and nothing here would notice.
	func testResolve_ExplicitProductIDs_OverrideTheDefault() {
		XCTAssertNil(EntitlementResolver.resolve([candidate()], productIDs: [foreignID]))
		XCTAssertNotNil(EntitlementResolver.resolve([candidate(productID: foreignID)], productIDs: [foreignID]))
	}
}
