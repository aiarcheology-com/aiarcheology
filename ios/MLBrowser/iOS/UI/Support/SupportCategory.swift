//
//  SupportCategory.swift
//  AI Archeology
//
//  Structured support requests (AIA-0440 Stage 1).
//

import Foundation

/// The kind of help a user is asking for.
///
/// The six cases are the set specified in AIA-0440: letting people classify the request up front
/// is the difference between a support inbox that can be triaged and one that cannot.
///
/// `rawValue` is a **stable tag**, spelled out explicitly rather than synthesised from the case
/// name, and it is what reaches the subject line — so inbox filters and labels key off it. Never
/// branch on the case *name* at runtime: names are build-time artifacts that a release build may
/// rename, while this contract has to survive one. Same discipline as ``FeatureFlagKey``.
enum SupportCategory: String, CaseIterable, Identifiable {
	// swiftlint:disable redundant_string_enum_value
	// Not redundant: these literals are the contract with the support inbox's filters. Letting
	// Swift synthesise them would tie a durable tag to a local symbol name.
	case bug = "bug"
	case purchase = "purchase"
	case account = "account"
	case featureRequest = "featureRequest"
	case privacy = "privacy"
	case other = "other"
	// swiftlint:enable redundant_string_enum_value

	var id: String { rawValue }

	/// The categories a user may pick from (AIA-0955).
	///
	/// With payments off the app sells nothing, so "Purchase or subscription" is withdrawn from the
	/// picker rather than offered as a category nobody could need. The case itself stays: it is a
	/// stable inbox tag, and payments can be switched back on.
	static func offered(isPaymentsSurfaceEnabled: Bool) -> [SupportCategory] {
		isPaymentsSurfaceEnabled ? allCases : allCases.filter { $0 != .purchase }
	}

	/// The user-facing name. Localized: this is a visible string (AGENTS.md §8).
	var displayName: String {
		switch self {
		case .bug: return L10n.Support.Category.bug
		case .purchase: return L10n.Support.Category.purchase
		case .account: return L10n.Support.Category.account
		case .featureRequest: return L10n.Support.Category.featureRequest
		case .privacy: return L10n.Support.Category.privacy
		case .other: return L10n.Support.Category.other
		}
	}
}
