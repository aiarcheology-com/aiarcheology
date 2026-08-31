//
//  ConfigCatFeatureFlagProvider.swift
//  AI Archeology
//
//  Remote feature flags via ConfigCat (AIA-0350).
//

import Foundation
import ConfigCat

/// Resolves feature flags from ConfigCat.
///
/// The **only** file that imports `ConfigCat`. Not `@MainActor` (Harmonize
/// `testServicesAreNotMainActor`).
///
/// Reads are synchronous against `client.snapshot()`, so nothing blocks launch. The SDK
/// owns freshness and persistence: it auto-polls and already caches config JSON in
/// `UserDefaults` under `com.configcat-`, so this type deliberately keeps **no cache of
/// its own** — a second cache would be a competing source of truth that could diverge
/// across SDK-key/environment changes.
///
/// A snapshot taken before the SDK's cache sync completes returns the supplied default;
/// that is safe by construction, and ``FeatureFlagsState`` republishes once config lands.
final class ConfigCatFeatureFlagProvider: FeatureFlagProviding {
	/// `ConfigCatClient` is declared `@unchecked Sendable` by the vendor, which is what
	/// lets this provider be `Sendable` and its refresh run off the main actor.
	private let client: ConfigCatClient

	/// Poll interval. The SDK's 60s default is needlessly chatty for two rarely-changed
	/// booleans; ten minutes keeps us far inside the free tier's 5M downloads/month.
	/// Note this only ticks while the process is alive — a suspended app does not poll,
	/// so this is a foreground-only bound on kill-switch latency.
	private static let pollIntervalSeconds = 600

	private let changeStream: AsyncStream<Void>
	private let changeContinuation: AsyncStream<Void>.Continuation

	/// - Parameter sdkKey: environment-specific SDK key. `nil`/empty returns `nil` so the
	///   caller can fall back to compiled defaults rather than failing the launch.
	init?(sdkKey: String?) {
		guard let sdkKey, !sdkKey.isEmpty else { return nil }
		// Only the *fact* of a change matters — the observer re-reads the whole snapshot —
		// so coalesce bursts to the newest signal instead of growing an unbounded backlog.
		let (stream, continuation) = AsyncStream<Void>.makeStream(
			of: Void.self,
			bufferingPolicy: .bufferingNewest(1)
		)
		changeStream = stream
		changeContinuation = continuation
		client = ConfigCatClient.get(sdkKey: sdkKey) { options in
			options.pollingMode = PollingModes.autoPoll(autoPollIntervalInSeconds: Self.pollIntervalSeconds)
			// Subscribed through `options.hooks`, never `client.hooks`: a subscription added
			// after the client reaches its ready state can miss the notification outright
			// (vendor's own caveat, ConfigCatOptions.swift:90). The snapshot variant is the
			// non-deprecated overload; both arguments are ignored because the observer
			// re-reads `currentSnapshot()` rather than trust a pushed payload.
			options.hooks.addOnConfigChanged(snapshotHandler: { _, _ in continuation.yield() })
		}
	}

	deinit {
		changeContinuation.finish()
	}

	func changes() -> AsyncStream<Void> { changeStream }

	func currentSnapshot() -> FeatureFlagSnapshot {
		let snapshot = client.snapshot()
		var values: [FeatureFlagKey: Bool] = [:]
		for key in FeatureFlagKey.allCases {
			values[key] = snapshot.getValue(for: key.rawValue, defaultValue: key.defaultValue)
		}
		let appMessagesJSON: String = snapshot.getValue(
			for: RemoteSettingKey.appMessages,
			defaultValue: ""
		)
		return FeatureFlagSnapshot(values: values, appMessagesJSON: appMessagesJSON)
	}

	func refresh() async {
		// Result deliberately ignored: a failed refresh leaves the previous values (or the
		// compiled defaults) in place. Flags are best-effort and must never surface an error.
		_ = await client.forceRefresh()
	}

	func setUser(id: String, custom: [String: String]) {
		client.setDefaultUser(user: ConfigCatUser(identifier: id, custom: custom))
	}

	func clearUser() {
		client.clearDefaultUser()
	}

	/// The SDK key for this build: Debug talks to the ConfigCat **Test** environment,
	/// every other configuration — TestFlight included — talks to **Production**.
	///
	/// The split is on build configuration, deliberately **not** on distribution channel.
	/// A TestFlight binary is promoted to the App Store unchanged, so it has to read the
	/// same flags it will read once released; pointing it at Test would validate the
	/// release candidate against config it never sees in production.
	///
	/// `ClerkAuthProvider.publishableKey` now reaches the same conclusion by a different route:
	/// it reads `BackendEnvironment`, fixed at build time from `AIA_BACKEND_ENVIRONMENT`, which
	/// is `production` for every Release build including TestFlight (AIA-0791). It used to key
	/// off `isAppStoreDistribution` and send TestFlight to the dev instance. The two settings are
	/// still separate knobs — do not collapse them into one without reading this comment.
	///
	/// Consequence, which is the real cost: there is no tester-only flag. Flipping a flag
	/// reaches TestFlight and live App Store users alike.
	static func sdkKeyFromInfoPlist() -> String? {
		let key = AppEnvironment.isDebugConfiguration ? "ConfigCatSDKKey" : "ConfigCatSDKKeyLive"
		return Bundle.main.object(forInfoDictionaryKey: key) as? String
	}
}
