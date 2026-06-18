//
//  TourTarget.swift
//  AI Archeology
//
//  AIA-0333: interactive onboarding spotlight tour — anchor plumbing.
//

import SwiftUI

/// Collects the bounds anchors of every `.tourTarget(_:)` in the subtree, keyed by id.
/// The root `.tourOverlay(_:)` reads this through `overlayPreferenceValue`.
struct TourAnchorPreferenceKey: PreferenceKey {
	static let defaultValue: [TourAnchorID: Anchor<CGRect>] = [:]

	static func reduce(
		value: inout [TourAnchorID: Anchor<CGRect>],
		nextValue: () -> [TourAnchorID: Anchor<CGRect>]
	) {
		// Last writer wins; targets are unique, so collisions don't occur in practice.
		value.merge(nextValue()) { _, new in new }
	}
}

extension View {
	/// Marks this view as a tour spotlight target. Layout-driven via `anchorPreference`, so
	/// the cutout follows chrome show/hide and orientation automatically.
	func tourTarget(_ id: TourAnchorID) -> some View {
		anchorPreference(key: TourAnchorPreferenceKey.self, value: .bounds) { [id: $0] }
	}
}
