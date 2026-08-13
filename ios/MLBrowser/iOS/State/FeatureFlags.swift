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

	/// Gates the native App Store rating request offered after a positive moment — a finding saved,
	/// or a model imported/converted (AIA-0117). Turning it off stops the app from *asking*; it has
	/// no bearing on reviews the user writes from the App Store themselves. Fails open so a config
	/// outage does not silently remove a shipped behaviour.
	case isRatingPromptEnabled = "isRatingPromptEnabled"
	/// Gates the app→user messaging surface (AIA-0115): whether remotely-published messages
	/// (the `appMessages` setting) render at all. Fails open — safe because the content
	/// setting itself defaults to empty, so an outage shows no messages rather than stale ones.
	case isAppMessagingEnabled = "isAppMessagingEnabled"

	/// Gates the cross-device, Clerk-derived analytics identity (AIA-0437): whether a signed-in
	/// account is attributed consistently across their devices instead of falling back to the
	/// per-device installation identity — and, with it, whether the analytics choice is scoped to
	/// the account rather than the device.
	///
	/// **Fails open**, like every other flag here, and deliberately so after review.
	///
	/// The tempting argument is that an account-linked identity should never switch itself on. It
	/// does not: the flag never gates consent, it only selects *which consent model* is in force,
	/// and an account must explicitly agree either way. So a `false` default protected nothing —
	/// while actively causing harm. With the flag on in the dashboard, a single offline cold launch
	/// would read the compiled `false`, re-prompt a consented user in device-wide mode, and clear
	/// their `analyticsConsentAccountHash` — destroying the account-scoped record and prompting them
	/// again when the flag came back. Failing open removes that path entirely.
	case isCrossDeviceAnalyticsIdentityEnabled = "isCrossDeviceAnalyticsIdentityEnabled"

	/// Gates the 14-day app-managed free-access window in front of the paywall (AIA-0556):
	/// whether a device that has never had one is **granted** a window.
	///
	/// It governs *granting* only. A window already open is honoured to its natural expiry
	/// regardless of what this reads later, so turning it off is not a way to wall someone
	/// mid-window — that would replace a working app with a paywall, which is exactly the
	/// root-gate churn AIA-0350 forbids.
	///
	/// **Fails open**, like every other flag here, and the consequence is worth stating plainly.
	/// This flag is launch-captured, and a genuine first launch has no mirror to read
	/// (`LaunchCapturedFlags.resolve`), so it resolves to this compiled default. A first launch is
	/// also the *only* moment a window can be granted. Therefore a `false` default would make the
	/// feature unreachable for every new user — the exact population it exists for — while looking
	/// perfectly correct in tests, which inject a synchronous provider and take the other branch.
	///
	/// The price of `true` is the honest limit of this kill switch: switching it off in the
	/// dashboard stops grants for the existing install base from their next launch, but a brand-new
	/// install still receives one window, because its first launch precedes any sync. Accepted
	/// deliberately — the exposure is free *app use*, never free subscription time, which Apple
	/// tracks per Apple ID server-side and this app cannot give away.
	case isFreeAccessPeriodEnabled = "isFreeAccessPeriodEnabled"

	/// Gates whether the application log is **persisted** across launches, and with it whether
	/// `.debug` entries are retained at all (AIA-0602).
	///
	/// An emergency brake, not a rollout control. This is the first release in two years and the
	/// store is new code that writes to every user's disk in a build that cannot be hot-fixed — if it
	/// misbehaves in the field (storage growth, a wedged write path), App Review latency would
	/// otherwise put a full release cycle between the report and the remedy.
	///
	/// Read **live**, not launch-captured. `FeatureFlagsState` observes the provider's change stream,
	/// so flipping this in the dashboard takes effect without a relaunch; a launch-captured flag
	/// would not engage until every user had cold-started, which is no use in an emergency.
	///
	/// **Fails open**, like every other flag here, and the reason is specific: this ships to gather
	/// diagnostics on a release nobody has field data for. A `false` default would mean a ConfigCat
	/// outage — or a genuine first launch, before any sync — silently disabling the very thing we are
	/// relying on to see what went wrong.
	///
	/// Turning it off does **not** mean no diagnostics. It falls back to the pre-AIA-0602 behaviour:
	/// a session-scoped in-memory log, still attachable to a support report, without persistence and
	/// without debug entries. It also deletes what has already been stored — a brake that stopped
	/// writing but left raw addresses on disk would be worse than no brake.
	case isDetailedApplicationLogEnabled = "isDetailedApplicationLogEnabled"
	// swiftlint:enable redundant_string_enum_value

	/// The value used when remote config cannot be consulted.
	var defaultValue: Bool {
		switch self {
		case .isModelCatalogEnabled: return true
		case .isPaymentsEnabled: return true
		case .isAnalyticsEnabled: return true
		case .isSupportReportingEnabled: return true
		case .isRatingPromptEnabled: return true
		case .isAppMessagingEnabled: return true
		case .isCrossDeviceAnalyticsIdentityEnabled: return true
		case .isFreeAccessPeriodEnabled: return true
		case .isDetailedApplicationLogEnabled: return true
		}
	}
}

/// Resolution for flags captured **once per session** rather than observed live (AIA-0513).
///
/// A launch-captured flag cannot read the live snapshot: `FeatureFlagsState` seeds synchronously
/// and the ConfigCat SDK has not synced by then — not even from its own on-disk cache — so the read
/// returns the compiled default on *every* launch and the dashboard is inert in both directions.
/// Flags read live are unaffected, because they observe the republish; flags captured once never do.
///
/// The fix is a one-launch delay: each session mirrors what it observes, and the next session
/// captures the mirror. Pure and static so it is testable without the composition root.
enum LaunchCapturedFlags {
	/// The values to persist for the next launch, taken from an observed (post-sync) snapshot.
	static func mirror(from snapshot: FeatureFlagSnapshot) -> [String: Bool] {
		var values: [String: Bool] = [:]
		for key in FeatureFlagKey.allCases { values[key.rawValue] = snapshot[key] }
		return values
	}

	/// The value to capture for `key`: the previous session's observation, or the live snapshot
	/// when nothing has been observed yet (a genuine first launch, or a test whose provider is
	/// synchronous and therefore trustworthy at construction).
	static func resolve(
		_ key: FeatureFlagKey,
		mirror: [String: Bool],
		snapshot: FeatureFlagSnapshot
	) -> Bool {
		mirror[key.rawValue] ?? snapshot[key]
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
	var isRatingPromptEnabled: Bool { self[.isRatingPromptEnabled] }
	var isAppMessagingEnabled: Bool { self[.isAppMessagingEnabled] }
	var isCrossDeviceAnalyticsIdentityEnabled: Bool { self[.isCrossDeviceAnalyticsIdentityEnabled] }
	var isFreeAccessPeriodEnabled: Bool { self[.isFreeAccessPeriodEnabled] }
	var isDetailedApplicationLogEnabled: Bool { self[.isDetailedApplicationLogEnabled] }

	/// Every key at its compiled default — the launch/offline value.
	static let defaults = FeatureFlagSnapshot()
}
