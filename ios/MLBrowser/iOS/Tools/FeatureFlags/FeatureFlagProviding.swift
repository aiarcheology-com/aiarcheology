//
//  FeatureFlagProviding.swift
//  AI Archeology
//
//  Remote feature flags (AIA-0350).
//

import Foundation

/// Source of resolved feature-flag values.
///
/// Deliberately narrow and internal: this is a test/preview seam, **not** a view-facing
/// API. Views read the published ``FeatureFlagSnapshot`` from `AppState`; exposing a
/// provider at the app boundary would be a fake abstraction — consumers need one typed
/// snapshot, not an indirection.
///
/// Implementations must be non-`@MainActor` (Harmonize `testServicesAreNotMainActor`)
/// and must resolve synchronously, so nothing blocks launch.
protocol FeatureFlagProviding: Sendable {
	/// The values known right now. Never blocks, never throws; unknown keys fall back to
	/// their compiled `defaultValue`.
	func currentSnapshot() -> FeatureFlagSnapshot

	/// Best-effort refresh from the remote source. Failures are swallowed by design.
	func refresh() async
}

/// A fixed provider for unit tests, SwiftUI previews, and UI tests. Never touches the
/// network, so test runs cannot be flaky on ConfigCat availability.
final class StaticFeatureFlagProvider: FeatureFlagProviding {
	private let snapshot: FeatureFlagSnapshot

	init(overrides: [FeatureFlagKey: Bool] = [:]) {
		self.snapshot = FeatureFlagSnapshot(values: overrides)
	}

	func currentSnapshot() -> FeatureFlagSnapshot { snapshot }

	func refresh() async {}
}
