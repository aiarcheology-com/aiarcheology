//
//  TelemetryDeckAnalyticsService.swift
//  AI Archeology
//
//  Optional, privacy-safe product analytics (AIA-0350).
//

import Foundation
import TelemetryDeck

/// The only type that imports and initializes TelemetryDeck. It owns a dedicated ephemeral
/// URLSession so disabling analytics cancels in-flight requests and clears the SDK cache created
/// by the pinned 2.14.1 implementation.
@MainActor
final class TelemetryDeckAnalyticsProvider: AnalyticsTracking {
	private static let appIDInfoPlistKey = "TelemetryDeckAppID"
	private static let signalCacheDirectoryName = "telemetrysignalcache"

	private var isInitialized = false
	private var urlSession: URLSession?
	private var configuration: TelemetryDeck.Config?

	/// The account identity every signal is attributed to, retained across activations.
	///
	/// `activate()` builds a **fresh** `TelemetryDeck.Config` each time it runs, which resets
	/// `defaultUser`. Without retaining the value here, any re-activation — a remote flag flip, or
	/// a re-enable after `deactivate()` — would silently fall back to the anonymous installation
	/// identity (AIA-0437). Deliberately *not* cleared by `deactivate()`: withdrawing consent and
	/// changing account are orthogonal, and the same account re-consenting must be re-attributed.
	private var accountIdentifier: String?

	/// Every TelemetryDeck symbol must be reached through here.
	///
	/// `TelemetryManager.shared` `assertionFailure`s when the SDK was never initialized and returns
	/// a throwaway manager whose `init` schedules another `generateNewSession()` half a second
	/// later — which re-enters `TelemetryManager.shared`. So one unguarded call traps in DEBUG and,
	/// in Release, spawns managers indefinitely and reaches the network with no consent at all.
	/// Keeping the guard in exactly one place is what stops a future method from forgetting it.
	private func withInitializedSDK(_ body: () -> Void) {
		guard isInitialized, configuration?.analyticsDisabled == false else { return }
		body()
	}

	func activate() {
		guard let appID = Self.appIDFromInfoPlist() else {
			LoggingPolicy.warning("TelemetryDeck is not configured; optional analytics remain disabled", logger: .lifecycle)
			return
		}
		if isInitialized, configuration?.analyticsDisabled == false {
			return
		}

		// SwiftSDK 2.14.1 installs delayed foreground observers which are not removable through
		// its public API. While disabled we therefore retain a manager whose
		// `analyticsDisabled` guard is true. Re-enabling replaces that dormant manager only after
		// cancellation and cache clearing, so an old in-memory queue can never use the new session.
		if isInitialized {
			TelemetryDeck.terminate()
		}

		let configuration = URLSessionConfiguration.ephemeral
		let session = URLSession(configuration: configuration)
		let telemetryConfiguration = TelemetryDeck.Config(appID: appID)
		telemetryConfiguration.urlSession = session
		// Seeded BEFORE `initialize`, not after: initialization itself emits the SDK's automatic
		// session signal, and `SignalManager` reads `configuration.defaultUser` when it hashes.
		// Applying the identity afterwards would leave that first signal anonymous (AIA-0437).
		telemetryConfiguration.defaultUser = accountIdentifier
		TelemetryDeck.initialize(config: telemetryConfiguration)
		urlSession = session
		self.configuration = telemetryConfiguration
		isInitialized = true
	}

	func deactivate() {
		// Clear the transport's identity while the SDK is still live. After `analyticsDisabled`
		// flips below, `withInitializedSDK` (correctly) refuses to touch the SDK, so the identity
		// would otherwise survive on the retained manager. No session rotation: nothing more will
		// be sent, and the next `activate()` builds a fresh Config with a fresh session anyway.
		withInitializedSDK {
			TelemetryDeck.updateDefaultUserID(to: nil)
		}
		// Cancel first, so no queued request can escape while the choice is being withdrawn.
		urlSession?.invalidateAndCancel()
		urlSession = nil
		// Do not terminate here: SwiftSDK 2.14.1 has delayed foreground observers that use the
		// global manager. Keeping this inert manager avoids a later observer creating a fallback
		// manager with the shared URLSession. `analyticsDisabled` guards both custom and automatic
		// signals. The manager is replaced safely on a later active opt-in (see `activate()`).
		configuration?.analyticsDisabled = true
		clearSignalCache()
	}

	func track(_ event: AnalyticsEvent) {
		withInitializedSDK {
			// `customUserID` is bound HERE, at call time. The transport's own `defaultUser` is read
			// later, on a queue hop inside `processSignal` — so an identity change landing after
			// this call but before that queue drains would otherwise re-attribute this event to the
			// NEW account. Passing the identity explicitly is what pins it (AIA-0437).
			TelemetryDeck.signal(
				event.name,
				parameters: event.parameters,
				customUserID: accountIdentifier
			)
		}
	}

	func updateAccountIdentity(_ identifier: String?) {
		// Normalise blank to nil: the SDK's "no custom identity" test is `defaultUser == nil`, so an
		// empty string counts as a real identifier and would hash every signed-out user into one
		// shared bucket.
		let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
		let newValue = trimmed?.isEmpty == false ? trimmed : nil
		guard newValue != accountIdentifier else { return }
		accountIdentifier = newValue
		withInitializedSDK {
			TelemetryDeck.updateDefaultUserID(to: newValue)
			// Rotate on EVERY identity change, including a clear. `sessionID` rides every signal,
			// so a shared session is enough to join two identities together — and that is just as
			// true for account-to-anonymous as for account-to-account. Not conditioning it on the
			// new value also removes a dependency on callers always deactivating after a clear,
			// which is the kind of assumption that quietly stops holding.
			// Ordering is load-bearing: the rotation itself emits a session signal, which must
			// carry the identity we moved TO — hence strictly after the identity is set.
			TelemetryDeck.generateNewSession()
		}
	}

	private static func appIDFromInfoPlist() -> String? {
		guard let value = Bundle.main.object(forInfoDictionaryKey: appIDInfoPlistKey) as? String else {
			return nil
		}
		let appID = value.trimmingCharacters(in: .whitespacesAndNewlines)
		// A missing local xcconfig leaves the build-setting placeholder untouched. Treat it as
		// unconfigured rather than accidentally sending a malformed identifier.
		guard appID.isEmpty == false, appID.hasPrefix("$(").not else { return nil }
		return appID
	}

	private func clearSignalCache() {
		guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
			return
		}
		let cacheURL = cachesDirectory.appendingPathComponent(Self.signalCacheDirectoryName, isDirectory: true)
		try? FileManager.default.removeItem(at: cacheURL)
	}
}
