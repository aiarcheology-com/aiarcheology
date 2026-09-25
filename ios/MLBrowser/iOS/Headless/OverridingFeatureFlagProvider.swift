//
//  OverridingFeatureFlagProvider.swift
//  AI Archeology
//
//  AIA-0970.
//

#if DEBUG
import Foundation

/// The live provider with some flags pinned, for headless launches (`-headlessFlag`).
///
/// A decorator **upstream of** `FeatureFlagsState`, on purpose. Everything downstream — the published
/// snapshot, the change stream, and `FlagLaunchValueMirror`, which launch-captured flags such as
/// `isPaymentsEnabled` resolve through on the *next* launch — then sees the pinned values. Pinning
/// only the first snapshot would let the live value leak into that mirror and silently undo the pin
/// one relaunch later.
final class OverridingFeatureFlagProvider: FeatureFlagProviding {

	private let base: FeatureFlagProviding
	private let overrides: [FeatureFlagKey: Bool]

	init(base: FeatureFlagProviding, overrides: [FeatureFlagKey: Bool]) {
		self.base = base
		self.overrides = overrides
	}

	func currentSnapshot() -> FeatureFlagSnapshot {
		let live = base.currentSnapshot()
		var values: [FeatureFlagKey: Bool] = [:]
		for key in FeatureFlagKey.allCases {
			values[key] = overrides[key] ?? live[key]
		}
		return FeatureFlagSnapshot(values: values, appMessagesJSON: live.appMessagesJSON)
	}

	func refresh() async {
		await base.refresh()
	}

	/// The base provider's stream: observers re-read `currentSnapshot()`, which applies the pins.
	func changes() -> AsyncStream<Void> {
		base.changes()
	}

	func setUser(id: String, custom: [String: String]) {
		base.setUser(id: id, custom: custom)
	}

	func clearUser() {
		base.clearUser()
	}
}
#endif
