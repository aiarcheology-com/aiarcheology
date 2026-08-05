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

	// MARK: - priceTerm: the price-per-period the sign-up screen owes the buyer (AIA-0559)

	/// The composition must carry both halves. A price with no period is what App Review 3.1.2
	/// rejects, and it is what this screen shipped before.
	func test_priceTerm_singleMonth_carriesBothThePriceAndThePeriod() {
		let text = Product.SubscriptionPeriod.priceTerm(price: "$3.99", unit: .month, value: 1)
		XCTAssertTrue(text.contains("$3.99"), "Lost the price: \(text)")
		XCTAssertTrue(text.contains(L10n.Subscription.Period.month), "Never says what recurs: \(text)")
	}

	/// The period is *derived from the product*, never a hardcoded "month" — so a plan whose
	/// period changes in App Store Connect cannot strand the copy. Same price, different unit,
	/// different string: a literal would make these two equal.
	func test_priceTerm_yearlyAndMonthly_differOnTheTermAlone() {
		let yearly = Product.SubscriptionPeriod.priceTerm(price: "$39.99", unit: .year, value: 1)
		let monthly = Product.SubscriptionPeriod.priceTerm(price: "$39.99", unit: .month, value: 1)
		XCTAssertTrue(yearly.contains(L10n.Subscription.Period.year))
		XCTAssertNotEqual(yearly, monthly, "The term is hardcoded — a yearly plan would read as monthly.")
	}

	/// A multi-unit period keeps its count: "every 3 months" must not present itself as "/ month",
	/// which would understate the billing interval by a factor of three.
	func test_priceTerm_multiMonth_keepsTheCountRatherThanTheBareNoun() {
		XCTAssertEqual(
			Product.SubscriptionPeriod.priceTerm(price: "$9.99", unit: .month, value: 3),
			L10n.Subscription.planTerm("$9.99", Product.SubscriptionPeriod.localizedDescription(unit: .month, value: 3))
		)
	}

	/// The composed string is exactly the catalog's pattern filled in, in that argument order.
	///
	/// Note what this does **not** prove: with the English pattern being "%1$@ / %2$@", a
	/// hardcoded `"\(price) / \(term)"` would satisfy it too. It catches a wrong argument order or
	/// a lost placeholder, not a bypassed catalog — only a second localization could do that, and
	/// the catalog has one language today.
	func test_priceTerm_matchesTheCatalogPatternFilledIn() {
		XCTAssertEqual(
			Product.SubscriptionPeriod.priceTerm(price: "$3.99", unit: .month, value: 1),
			L10n.Subscription.planTerm("$3.99", L10n.Subscription.Period.month)
		)
	}

	/// VoiceOver gets the same fact without the punctuation: "per", not "slash". Same term, so a
	/// spoken form can never describe a different plan than the one on screen.
	func test_spokenPriceTerm_saysPerRatherThanTheSeparator_andKeepsTheSameTerm() {
		let spoken = Product.SubscriptionPeriod.spokenPriceTerm(price: "$3.99", unit: .month, value: 1)
		XCTAssertEqual(spoken, L10n.Subscription.planTermSpoken("$3.99", L10n.Subscription.Period.month))
		XCTAssertFalse(spoken.contains("/"), "The spoken form still carries the slash: \(spoken)")
		XCTAssertNotEqual(spoken, Product.SubscriptionPeriod.priceTerm(price: "$3.99", unit: .month, value: 1))
	}
}
