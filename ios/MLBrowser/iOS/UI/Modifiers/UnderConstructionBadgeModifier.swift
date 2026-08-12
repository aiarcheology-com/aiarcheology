//
//  UnderConstructionBadgeModifier.swift
//  AI Archeology
//
//  Flags a control as a test / under-construction element (AIA-0354).
//

import SwiftUI

/// Decorates a control with a loud "this is a test / under construction" treatment: a blue
/// border plus a `wrench.and.screwdriver` badge (black on yellow) in the top-right corner.
///
/// The point is to *scream* at a tester that the control isn't wired to real consequences —
/// the first user is the paywall **Subscribe** button, where in every non-production build the
/// purchase runs against Apple's Sandbox (no real money), so the badge says "safe to tap".
///
/// Gated by `isActive`, which defaults to `AppEnvironment.showsUnderConstructionBadge` — on in
/// development, UI tests, TestFlight/sandbox and the simulator, and off in production *and*
/// wherever the channel cannot be identified (AIA-0458: it fails closed, because the cost of a
/// false positive is a wrench on a paying customer's Subscribe button). The decoration is purely
/// cosmetic: it never intercepts taps and is hidden from accessibility, so the underlying control
/// behaves identically with or without it.
///
/// Usage:
/// ```swift
/// SubscribeButton()
///     .underConstructionBadge()                 // gated on the environment
///     .underConstructionBadge(isActive: true)   // forced on (previews / tests)
/// ```
struct UnderConstructionBadgeModifier: ViewModifier {
	/// When `false` the modifier is a pass-through and the content renders unchanged.
	var isActive: Bool

	func body(content: Content) -> some View {
		if isActive {
			content
				.overlay(alignment: .topTrailing) {
					Image(systemName: "wrench.and.screwdriver")
						.font(.caption.bold())
						.foregroundStyle(.black)
						.padding(5)
						.background(.yellow)
						.clipShape(.rect(cornerRadius: 8))
						.overlay(
							RoundedRectangle(cornerRadius: 8)
								.stroke(.black, lineWidth: 1)
						)
						.offset(x: 8, y: -8)
						.allowsHitTesting(false)
						.accessibilityHidden(true)
				}
		} else {
			content
		}
	}
}

extension View {
	/// Adds the test / under-construction decoration (see ``UnderConstructionBadgeModifier``).
	/// Defaults to active only in a build positively identified as non-production.
	func underConstructionBadge(isActive: Bool = AppEnvironment.showsUnderConstructionBadge) -> some View {
		modifier(UnderConstructionBadgeModifier(isActive: isActive))
	}
}
