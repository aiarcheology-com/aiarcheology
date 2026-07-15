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
/// API. Exposing a provider at the app boundary would be a fake abstraction — consumers
/// need one typed snapshot, not an indirection.
///
/// Views observe ``FeatureFlagsState`` **directly** (`@EnvironmentObject`) and read its
/// `snapshot`. `AppState` owns that state, but a view must not reach through it: nested
/// `ObservableObject`s do not republish through their parent, so a flag gated via
/// `appState.featureFlags` compiles, works at launch, and then silently misses every live
/// update. See FEATUREFLAGS.md and AGENTS.md §3.
///
/// Implementations must be non-`@MainActor` (Harmonize `testServicesAreNotMainActor`)
/// and must resolve synchronously, so nothing blocks launch.
protocol FeatureFlagProviding: Sendable {
	/// The values known right now. Never blocks, never throws; unknown keys fall back to
	/// their compiled `defaultValue`.
	func currentSnapshot() -> FeatureFlagSnapshot

	/// Best-effort refresh from the remote source. Failures are swallowed by design.
	func refresh() async

	/// Signals that the resolved values may have changed — most importantly when the SDK's
	/// own auto-poll lands new config, which no call of ours triggers.
	///
	/// Carries `Void` rather than a snapshot: the observer re-reads
	/// ``currentSnapshot()`` anyway, so the payload would only be a second source of truth
	/// to keep in sync. An `AsyncStream` rather than the codebase's usual Combine subject
	/// because this crosses a non-isolated provider → `@MainActor` state boundary, and
	/// Combine's subjects are not `Sendable` under Swift 6.
	///
	/// Single-consumer: an `AsyncStream` may only be iterated once.
	func changes() -> AsyncStream<Void>
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

	/// Finishes immediately: these values are fixed for the provider's lifetime, so an
	/// observer's `for await` loop should exit at once rather than park forever on a
	/// stream that can never yield.
	func changes() -> AsyncStream<Void> {
		AsyncStream { $0.finish() }
	}
}
