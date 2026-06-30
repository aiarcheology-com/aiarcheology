//
//  SubscriptionPeriodLocalizedTests.swift
//  AI ArcheologyTests
//
//  Covers Product.SubscriptionPeriod localized term/description (AIA-0354).
//

import XCTest
import StoreKit
@testable import ML_Browser

/// `Product.SubscriptionPeriod` has no public initializer, so we exercise the static
/// `(unit:value:)` entry points — `Product.SubscriptionPeriod.Unit` is constructible.
final class SubscriptionPeriodLocalizedTests: XCTestCase {

	// MARK: - localizedTerm: single-unit collapses to the bare noun

	func test_localizedTerm_singleMonth_isBareMonthNoun() {
		XCTAssertEqual(
			Product.SubscriptionPeriod.localizedTerm(unit: .month, value: 1),
			L10n.Subscription.Period.month
		)
	}

	func test_localizedTerm_singleYear_isBareYearNoun() {
		XCTAssertEqual(
			Product.SubscriptionPeriod.localizedTerm(unit: .year, value: 1),
			L10n.Subscription.Period.year
		)
	}

	func test_localizedTerm_singleWeek_isBareWeekNoun() {
		XCTAssertEqual(
			Product.SubscriptionPeriod.localizedTerm(unit: .week, value: 1),
			L10n.Subscription.Period.week
		)
	}

	func test_localizedTerm_singleDay_isBareDayNoun() {
		XCTAssertEqual(
			Product.SubscriptionPeriod.localizedTerm(unit: .day, value: 1),
			L10n.Subscription.Period.day
		)
	}

	// MARK: - localizedTerm: multi-unit does NOT collapse (no "every 3 months" → "month")

	func test_localizedTerm_multiMonth_doesNotCollapseToBareNoun() {
		let term = Product.SubscriptionPeriod.localizedTerm(unit: .month, value: 3)
		XCTAssertNotEqual(term, L10n.Subscription.Period.month)
		XCTAssertFalse(term.isEmpty)
	}

	// MARK: - localizedDescription always keeps the count form

	func test_localizedDescription_singleMonth_isNonEmptyCountForm() {
		// Count form is the trial-copy style ("1 month") — never collapsed to the bare noun.
		let description = Product.SubscriptionPeriod.localizedDescription(unit: .month, value: 1)
		XCTAssertFalse(description.isEmpty)
		XCTAssertNotEqual(description, L10n.Subscription.Period.month)
	}
}
