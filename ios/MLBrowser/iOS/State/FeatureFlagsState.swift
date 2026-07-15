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
@MainActor
final class FeatureFlagsState: ObservableObject {
	@Published private(set) var snapshot: FeatureFlagSnapshot

	private let provider: FeatureFlagProviding

	init(provider: FeatureFlagProviding) {
		self.provider = provider
		self.snapshot = provider.currentSnapshot()
	}

	/// Best-effort refresh. Never throws; on failure the previous snapshot stands.
	///
	/// Republishes only on an actual change, so an unchanged poll does not churn the view
	/// graph every ten minutes.
	func refresh() async {
		await provider.refresh()
		let refreshed = provider.currentSnapshot()
		if refreshed != snapshot {
			snapshot = refreshed
		}
	}
}
