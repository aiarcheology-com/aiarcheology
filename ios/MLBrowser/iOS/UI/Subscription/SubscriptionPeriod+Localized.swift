//
//  SubscriptionPeriod+Localized.swift
//  AI Archeology
//
//  Localized, locale-aware formatting for a StoreKit subscription period (AIA-0354).
//

import Foundation
import StoreKit

extension Product.SubscriptionPeriod {
	/// Count + unit, locale-aware: "1 month", "7 days", "3 months". Used for the free-trial
	/// copy on the paywall, where the *length* of the offer matters.
	var localizedDescription: String {
		Self.localizedDescription(unit: unit, value: value)
	}

	/// The term suffix for a recurring price ("$3.99 / **month**"). For a period of one unit
	/// this is the bare unit noun ("month", "year"); for a multi-unit period it falls back to
	/// the count form ("3 months"), so a quarterly/biweekly plan still reads correctly.
	var localizedTerm: String {
		Self.localizedTerm(unit: unit, value: value)
	}

	/// `Product.SubscriptionPeriod` has no public initializer, so the formatting logic lives on
	/// `Unit` + `value` (both constructible) to stay unit-testable.
	static func localizedDescription(unit: Unit, value: Int) -> String {
		var components = DateComponents()
		// Restrict the formatter to the period's own unit so it can't re-express the period
		// (e.g. a 1-week period rendering as "7 days", or 30 days as "1 month").
		let allowedUnit: NSCalendar.Unit
		switch unit {
		case .day: components.day = value; allowedUnit = .day
		case .week: components.weekOfMonth = value; allowedUnit = .weekOfMonth
		case .month: components.month = value; allowedUnit = .month
		case .year: components.year = value; allowedUnit = .year
		@unknown default: components.day = value; allowedUnit = .day
		}
		let formatter = DateComponentsFormatter()
		formatter.unitsStyle = .full
		formatter.allowedUnits = allowedUnit
		formatter.maximumUnitCount = 1
		return formatter.string(from: components) ?? "\(value)"
	}

	static func localizedTerm(unit: Unit, value: Int) -> String {
		// Only a single-unit period collapses to the bare noun; otherwise keep the count so
		// "every 3 months" doesn't masquerade as "month".
		guard value == 1 else { return localizedDescription(unit: unit, value: value) }
		switch unit {
		case .day: return L10n.Subscription.Period.day
		case .week: return L10n.Subscription.Period.week
		case .month: return L10n.Subscription.Period.month
		case .year: return L10n.Subscription.Period.year
		@unknown default: return localizedDescription(unit: unit, value: value)
		}
	}

	/// A price joined to the term it recurs over — "$3.99 / month" (AIA-0559).
	///
	/// Separate from ``localizedTerm`` so the join lives in one place: this exact string is both
	/// what Settings calls the current plan and what App Review 3.1.2 requires the sign-up screen
	/// to state. Two implementations could drift, and the direction that drifts is a rejection.
	static func priceTerm(price: String, unit: Unit, value: Int) -> String {
		L10n.Subscription.planTerm(price, localizedTerm(unit: unit, value: value))
	}

	/// The same fact, spoken: "$3.99 per month".
	///
	/// The displayed form joins with "/", which VoiceOver announces as "slash". On a purchase
	/// screen the price is the headline, so it gets a spoken alternative rather than making
	/// someone parse punctuation.
	static func spokenPriceTerm(price: String, unit: Unit, value: Int) -> String {
		L10n.Subscription.planTermSpoken(price, localizedTerm(unit: unit, value: value))
	}
}

extension Product {
	/// This product's recurring price with the period it recurs over — "$3.99 / month".
	///
	/// Both parts come from the product, so App Store Connect stays the single source of truth:
	/// change the price or the period there and the copy follows without a build.
	///
	/// Falls back to the bare price when the product carries no subscription period. That branch
	/// is unreachable for the product this app sells — `SubscriptionState.products` only ever
	/// holds the auto-renewable subscription, and StoreKit always gives one a period — so it
	/// exists to keep a surprising payload from blanking the price, not as a supported rendering.
	var localizedPriceWithTerm: String {
		guard let period = subscription?.subscriptionPeriod else { return displayPrice }
		return Product.SubscriptionPeriod.priceTerm(price: displayPrice, unit: period.unit, value: period.value)
	}

	/// ``localizedPriceWithTerm`` for VoiceOver — "$3.99 per month". Same fallback, same reason.
	var spokenPriceWithTerm: String {
		guard let period = subscription?.subscriptionPeriod else { return displayPrice }
		return Product.SubscriptionPeriod.spokenPriceTerm(price: displayPrice, unit: period.unit, value: period.value)
	}
}
