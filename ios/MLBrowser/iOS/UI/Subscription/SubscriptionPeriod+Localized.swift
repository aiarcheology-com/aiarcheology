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
}
