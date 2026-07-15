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
/// outage. These defaults **fail open** — a "killed" feature stays on for any client that
/// never fetches. That is deliberate (it preserves shipped behaviour), but it means this
/// is not a guaranteed remote kill switch.
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
	// swiftlint:enable redundant_string_enum_value

	/// The value used when remote config cannot be consulted.
	var defaultValue: Bool {
		switch self {
		case .isModelCatalogEnabled: return true
		case .isPaymentsEnabled: return true
		}
	}
}

/// An immutable set of resolved flag values.
///
/// A value type on purpose: an `ObservableObject` here would need an approved suffix
/// (Harmonize `testObservableObjectsHaveDescriptiveSuffixes`), and the observable owner
/// is ``FeatureFlagsState``. Any key absent from `values` resolves to its `defaultValue`.
struct FeatureFlagSnapshot: Equatable {
	private let values: [FeatureFlagKey: Bool]

	init(values: [FeatureFlagKey: Bool] = [:]) {
		self.values = values
	}

	subscript(key: FeatureFlagKey) -> Bool {
		values[key] ?? key.defaultValue
	}

	var isModelCatalogEnabled: Bool { self[.isModelCatalogEnabled] }
	var isPaymentsEnabled: Bool { self[.isPaymentsEnabled] }

	/// Every key at its compiled default — the launch/offline value.
	static let defaults = FeatureFlagSnapshot()
}
