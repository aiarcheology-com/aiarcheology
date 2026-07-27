//
//  FeatureFlags.swift
//  AI Archeology
//
//  Feature flag keys + compiled defaults (AIA-0343, AIA-0413; remote via AIA-0350).
//  See AGENTS.md §3 "Feature flags" and FEATUREFLAGS.md.
//

import Foundation

/// A remotely-switchable feature flag.
///
/// The `rawValue` **is** the ConfigCat setting key — spelled out as an explicit literal,
/// deliberately never left to Swift's implicit synthesis from the case name. Renaming a
/// case must not silently repoint the lookup at a key the dashboard has never heard of:
/// that failure is invisible, because a missed lookup just returns `defaultValue`.
///
/// `defaultValue` is the compiled fallback used whenever remote config cannot be
/// consulted: first launch, offline, a bad SDK key, a missing flag, or a ConfigCat
/// outage. Each flag deliberately chooses whether that path fails open or closed; the choice
/// is part of its privacy and product contract, not an implementation detail.
enum FeatureFlagKey: String, CaseIterable {
	// swiftlint:disable redundant_string_enum_value
	// The rule is right in general and wrong here: these literals are not redundant, they
	// are the contract with the ConfigCat dashboard. Letting Swift synthesise them would
	// tie a remote key to a local symbol name, so a rename would silently repoint the
	// lookup at a key that does not exist — and a missed lookup is invisible, because it
	// just returns `defaultValue`. Keep them spelled out; `test_rawValues_areTheConfigCatKeys`
	// is the second lock on the same door.

	/// Gates the public model-catalog acquisition surface (AIA-0413).
	case isModelCatalogEnabled = "isModelCatalogEnabled"

	/// Gates the in-app subscription/paywall surface (AIA-0343): the Settings
	/// "Upgrade" entry point and any feature gated on entitlement.
	case isPaymentsEnabled = "isPaymentsEnabled"

	/// Master switch for optional TelemetryDeck analytics. The user-level setting remains off by
	/// default; this flag only controls whether that user choice is available in the app.
	case isAnalyticsEnabled = "isAnalyticsEnabled"

	/// Gates **only** the screenshot-triggered "report a problem" offer (AIA-0454) — not the
	/// support flow itself. Settings → About → Report a problem stays reachable regardless, so
	/// turning this off costs nobody their support route; it silences an unsolicited prompt.
	/// Rollout is controlled by the ConfigCat value, not by the compiled default.
	case isSupportReportingEnabled = "isSupportReportingEnabled"

	/// Gates **only** the Settings → Account → Subscription "Request a Refund" row (AIA-0461) —
	/// whether that entry point is offered at all. Turning it off hides the row; the refund itself
	/// is always available to the user through the App Store. Fails open so a config outage never
	/// removes it silently.
	case isRefundRequestEnabled = "isRefundRequestEnabled"

	/// Gates the native App Store rating request offered after a positive moment — a finding saved,
	/// or a model imported/converted (AIA-0117). Turning it off stops the app from *asking*; it has
	/// no bearing on reviews the user writes from the App Store themselves. Fails open so a config
	/// outage does not silently remove a shipped behaviour.
	case isRatingPromptEnabled = "isRatingPromptEnabled"
	/// Gates the app→user messaging surface (AIA-0115): whether remotely-published messages
	/// (the `appMessages` setting) render at all. Fails open — safe because the content
	/// setting itself defaults to empty, so an outage shows no messages rather than stale ones.
	case isAppMessagingEnabled = "isAppMessagingEnabled"
	// swiftlint:enable redundant_string_enum_value

	/// The value used when remote config cannot be consulted.
	var defaultValue: Bool {
		switch self {
		case .isModelCatalogEnabled: return true
		case .isPaymentsEnabled: return true
		case .isAnalyticsEnabled: return true
		case .isSupportReportingEnabled: return true
		case .isRefundRequestEnabled: return true
		case .isRatingPromptEnabled: return true
		case .isAppMessagingEnabled: return true
		}
	}
}

/// Keys of non-boolean settings served from the same ConfigCat config.
///
/// Same contract as `FeatureFlagKey.rawValue`: the literal **is** the dashboard key, and a
/// drifted key fails invisibly (the lookup just returns the default), so each constant is
/// locked by `test_rawValues_areTheConfigCatKeys`.
enum RemoteSettingKey {
	/// JSON array of app-messaging payloads (AIA-0115), decoded by `AppMessage.decodeMessages`.
	static let appMessages = "appMessages"
}

/// An immutable set of resolved flag values.
///
/// A value type on purpose: an `ObservableObject` here would need an approved suffix
/// (Harmonize `testObservableObjectsHaveDescriptiveSuffixes`), and the observable owner
/// is ``FeatureFlagsState``. Any key absent from `values` resolves to its `defaultValue`.
struct FeatureFlagSnapshot: Equatable {
	private let values: [FeatureFlagKey: Bool]

	/// Raw JSON of the `RemoteSettingKey.appMessages` setting; `""` when absent, unfetched,
	/// or offline (AIA-0115). Part of `Equatable` on purpose: a message edit must republish
	/// the snapshot exactly like a flag flip does.
	let appMessagesJSON: String

	init(values: [FeatureFlagKey: Bool] = [:], appMessagesJSON: String = "") {
		self.values = values
		self.appMessagesJSON = appMessagesJSON
	}

	subscript(key: FeatureFlagKey) -> Bool {
		values[key] ?? key.defaultValue
	}

	var isModelCatalogEnabled: Bool { self[.isModelCatalogEnabled] }
	var isPaymentsEnabled: Bool { self[.isPaymentsEnabled] }
	var isAnalyticsEnabled: Bool { self[.isAnalyticsEnabled] }
	var isSupportReportingEnabled: Bool { self[.isSupportReportingEnabled] }
	var isRefundRequestEnabled: Bool { self[.isRefundRequestEnabled] }
	var isRatingPromptEnabled: Bool { self[.isRatingPromptEnabled] }
	var isAppMessagingEnabled: Bool { self[.isAppMessagingEnabled] }

	/// Every key at its compiled default — the launch/offline value.
	static let defaults = FeatureFlagSnapshot()
}
