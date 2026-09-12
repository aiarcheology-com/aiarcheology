//
//  FlagLaunchValueMirror.swift
//  AI Archeology
//
//  Makes launch-captured feature flags reachable from the dashboard (AIA-0513).
//

import Combine
import Foundation

/// Persists each observed flag snapshot so the **next** launch can capture the dashboard's value
/// instead of the compiled default.
///
/// A flag captured once per session cannot read the live snapshot: `FeatureFlagsState` seeds
/// synchronously and the ConfigCat SDK has not synced by then — not even from its own on-disk
/// cache, which loads asynchronously. A launch-time read therefore returns the compiled default on
/// *every* launch, and the remote switch is inert in both directions. That is how the payments
/// kill switch was silently non-functional from AIA-0350 until this was found by hand.
///
/// Flags read *live* never had the problem: they observe the republish. Only captured-once flags
/// need this, and they pay one cold launch of latency for it.
///
/// **Must be constructed in the same synchronous frame as the `FeatureFlagsState` it observes.**
/// `dropFirst()` skips whatever is current at subscribe time, which is the compiled-defaults seed
/// only if nothing has synced yet. Arming later — after a background app-refresh has already
/// synced the state, say — would drop a genuine dashboard value instead, and `republish()` fires
/// only on change, so that session would mirror nothing at all.
@MainActor
final class FlagLaunchValueMirror {
	private var observation: AnyCancellable?

	init(flags: FeatureFlagsState, settings: Settings) {
		observation = flags.$snapshot
			// Skips the construction-time seed, which is the compiled defaults. Persisting that
			// would overwrite a real dashboard value with a placeholder.
			.dropFirst()
			.sink { [weak settings] snapshot in
				guard let settings else { return }
				let mirrored = LaunchCapturedFlags.mirror(from: snapshot)
				// Written only on an actual change, so an unchanged poll does not churn
				// `UserDefaults` or republish `Settings` to the view graph.
				guard mirrored != settings.remoteFlagLaunchValues else { return }
				settings.remoteFlagLaunchValues = mirrored
			}
	}
}
