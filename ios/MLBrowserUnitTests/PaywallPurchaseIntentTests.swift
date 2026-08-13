//
//  PaywallPurchaseIntentTests.swift
//  AI ArcheologyTests
//
//  What a tap on Subscribe does while an app-managed free window is still open (AIA-0623).
//

import XCTest
@testable import ML_Browser

final class PaywallPurchaseIntentTests: XCTestCase {

	// MARK: - No window open

	/// The root gate and every user past their window. `nil` is the ordinary answer here, not an
	/// error state: `FreeAccessState.windowDaysRemaining` reports it for a window that expired, one
	/// that was never granted, and one whose anchor has not been read yet.
	func testNoWindow_purchasesWithoutAsking() {
		XCTAssertEqual(PaywallPurchaseIntent.resolve(freeAccessDaysRemaining: nil), .purchase)
	}

	// MARK: - Window open

	/// The day-13 user: one day is still worth a sentence, because it is a day they paid for by
	/// waiting and would silently lose.
	func testOneDayLeft_asksFirst() {
		XCTAssertEqual(
			PaywallPurchaseIntent.resolve(freeAccessDaysRemaining: 1),
			.confirmForfeitingFreeAccess(remainingDays: 1)
		)
	}

	/// Day 0 of a standard grant — the largest forfeit the shipped window can produce.
	func testWholeWindowLeft_asksFirst() {
		XCTAssertEqual(
			PaywallPurchaseIntent.resolve(freeAccessDaysRemaining: 14),
			.confirmForfeitingFreeAccess(remainingDays: 14)
		)
	}

	/// The count is carried through untouched rather than re-derived, so the dialog can never state
	/// a different number from the one the gate is holding the user to.
	func testTheRemainingCountIsCarriedThroughUnchanged() {
		for days in 1...60 {
			XCTAssertEqual(
				PaywallPurchaseIntent.resolve(freeAccessDaysRemaining: days),
				.confirmForfeitingFreeAccess(remainingDays: days),
				"\(days) days must survive the decision unchanged"
			)
		}
	}

	// MARK: - Defensive

	/// **Unreachable from production, kept deliberately.** `FreeAccessWindow.remainingDays` floors at
	/// 1 and `phase(at:)` reports `.expired` below that, so neither value can arrive from the app.
	/// They are pinned because the failure they would cause is silent and expensive: a dialog
	/// announcing "You still have 0 free days" over a purchase the user is entitled to make without
	/// interruption.
	func testZeroOrNegativeDays_purchasesWithoutAsking() {
		XCTAssertEqual(PaywallPurchaseIntent.resolve(freeAccessDaysRemaining: 0), .purchase)
		XCTAssertEqual(PaywallPurchaseIntent.resolve(freeAccessDaysRemaining: -1), .purchase)
		XCTAssertEqual(PaywallPurchaseIntent.resolve(freeAccessDaysRemaining: Int.min), .purchase)
	}
}
