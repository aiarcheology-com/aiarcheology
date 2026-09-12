//
//  FeatureFlagsState.swift
//  AI Archeology
//
//  Remote feature flags (AIA-0350).
//

import Foundation
import Combine

/// Publishes the current ``FeatureFlagSnapshot`` to the UI.
///
/// `@MainActor` because Harmonize requires it of every `*State`
/// (`testStateObjectsAreMainActor`). It imports no SwiftUI/UIKit
/// (`testStateTypesAvoidSwiftUIImports_Aspirational`).
///
/// Seeded **synchronously** at construction so the first frame has real values without
/// waiting on the network; ``refresh()`` republishes once ConfigCat's cache sync or a
/// poll completes.
///
/// The launch `refresh()` alone is not enough to make a flag *live*: the SDK's auto-poll
/// updates its own cache without telling anyone, so a dashboard flip would sit unseen
/// until the next relaunch. Observing ``FeatureFlagProviding/changes()`` is what actually
/// closes that gap.
@MainActor
final class FeatureFlagsState: ObservableObject {
	@Published private(set) var snapshot: FeatureFlagSnapshot

	private let provider: FeatureFlagProviding

	/// Long-lived task draining the provider's change stream. Held so it lives for the
	/// app's lifetime and is cancelled if this state is ever torn down.
	private var changeObserver: Task<Void, Never>?

	init(provider: FeatureFlagProviding) {
		self.provider = provider
		self.snapshot = provider.currentSnapshot()
		changeObserver = Task { [weak self] in
			guard let changes = self?.provider.changes() else { return }
			for await _ in changes {
				guard let self else { return }
				self.republish()
			}
		}
	}

	deinit {
		changeObserver?.cancel()
	}

	/// Best-effort refresh. Never throws; on failure the previous snapshot stands.
	func refresh() async {
		await provider.refresh()
		republish()
	}

	/// Republishes only on an actual change, so neither an unchanged poll nor a no-op
	/// config push churns the view graph.
	private func republish() {
		let latest = provider.currentSnapshot()
		if latest != snapshot {
			snapshot = latest
		}
	}
}
